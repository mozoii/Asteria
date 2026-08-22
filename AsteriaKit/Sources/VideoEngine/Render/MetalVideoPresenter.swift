import Foundation
import QuartzCore
import Metal
import CoreVideo
import CoreGraphics
import os

/// Per-frame present decision: the wrapped planes plus whether to take the fused single pass or the upscaled two pass.
private struct FramePlan {
    let textures: YUVFrameTextures
    let width: Int
    let height: Int
    let presentation: PresentationPlan
    let upscale: Bool
    let drawSize: CGSize
}

/// C trampoline for `CGDisplayRegisterReconfigurationCallback`; forwards to the presenter passed as `userInfo`.
private func presenterReconfigurationCallback(_ display: CGDirectDisplayID,
                                              _ flags: CGDisplayChangeSummaryFlags,
                                              _ userInfo: UnsafeMutableRawPointer?) {
    guard let userInfo else { return }
    Unmanaged<MetalVideoPresenter>.fromOpaque(userInfo).takeUnretainedValue().handleReconfiguration(flags)
}

/// On-screen Metal present path driven by `CAMetalDisplayLink` on a dedicated render thread (off the main runloop).
/// Tags the layer BT.2020 PQ + EDR for HDR streams; the host's live `setHdrMode` re-tags on the next frame.
public final class MetalVideoPresenter: NSObject, CAMetalDisplayLinkDelegate, @unchecked Sendable {
    public let metalLayer: CAMetalLayer
    public private(set) var presentedCount = 0
    /// Present-path failures (a frame arrived but couldn't be prepared/encoded) — a silent present stall.
    public private(set) var prepareFailures = 0
    public private(set) var encodeFailures = 0
    /// Gates a single stall log so a stuck present path is diagnosable without log flooding.
    private var presentStallLogged = false

    /// Desired HDR state, updated off-thread by `setHDRActive`; the render thread reconciles the layer to it.
    private let hdrActive: OSAllocatedUnfairLock<Bool>
    /// Render-thread-only: the HDR tagging currently on the layer, and the mastering data already adopted.
    private var appliedHDR: Bool
    private var appliedMasteringData: Data?

    private let context: MetalRenderContext
    private let renderer: YUVToRGBRenderer
    private let holder: LatestFrameHolder
    private let presentRenderer: PresentRenderer
    private let fusedRenderer: FusedPresentRenderer
    private var renderThread: Thread?
    private var renderRunLoop: CFRunLoop?
    /// Signalled when the render thread exits, so teardown can block until the display link is fully removed.
    private var renderThreadDidFinish: DispatchSemaphore?
    /// Desired running state, so a reconfiguration's resume can't revive a presenter the stream already stopped.
    private var running = false
    /// True between a reconfiguration's begin and finalize callbacks, while the present path is torn down.
    private var suspendedForReconfig = false
    private var reconfigRegistered = false
    private let streamFps: Int
    private let displayMaxHz: Int?
    /// A non-10-bit stream can't carry PQ, so HDR is refused at init and for live `setHdrMode`.
    private let tenBit: Bool
    private var intermediate: MTLTexture?
    /// MetalFX spatial upscaler for sub-native streams; cached, recreated on input/target size change.
    private var upscaler: SpatialUpscaler?
    private var upscalerInput: (width: Int, height: Int)?
    private var upscaled: MTLTexture?
    private let enableMetalFX: Bool

    public init(holder: LatestFrameHolder, initialSize: CGSize,
                options: PresentOptions, tenBit: Bool = false) throws {
        self.enableMetalFX = options.enableMetalFX
        self.streamFps = options.streamFps
        self.displayMaxHz = options.displayMaxHz
        self.tenBit = tenBit
        let hdr = options.hdr && tenBit
        self.hdrActive = OSAllocatedUnfairLock(initialState: hdr)
        self.appliedHDR = hdr
        let context = try MetalRenderContext()
        self.context = context
        self.renderer = try YUVToRGBRenderer(context: context)
        self.holder = holder

        let layer = CAMetalLayer()
        layer.device = context.device
        layer.pixelFormat = Self.layerPixelFormat(tenBit: tenBit)
        layer.framebufferOnly = true
        layer.isOpaque = true
        layer.maximumDrawableCount = 3
        layer.colorspace = Self.layerColorspace(hdr: hdr)
        layer.wantsExtendedDynamicRangeContent = hdr
        // Seed a non-zero drawable size so the first vsync can allocate.
        layer.drawableSize = initialSize
        layer.contentsGravity = .resizeAspect
        self.metalLayer = layer

        // 10-bit present carries the same 4 bytes/px as 8-bit (bgr10a2 vs bgra8), so it's latency/bandwidth-neutral.
        self.presentRenderer = try PresentRenderer(context: context, pixelFormat: layer.pixelFormat, dither: tenBit)
        self.fusedRenderer = try FusedPresentRenderer(context: context, pixelFormat: layer.pixelFormat, dither: tenBit)
        super.init()
    }

    deinit { unregisterReconfigurationCallback() }

    /// Present layer/target format for the negotiated bit depth; both are 4 bytes/px so 10-bit adds no bandwidth.
    public static func layerPixelFormat(tenBit: Bool) -> MTLPixelFormat {
        tenBit ? .bgr10a2Unorm : .bgra8Unorm
    }

    /// Present colorspace for the dynamic range: BT.2020 PQ (the CSC already emits PQ codes) for HDR, else sRGB.
    public static func layerColorspace(hdr: Bool) -> CGColorSpace? {
        CGColorSpace(name: hdr ? CGColorSpace.itur_2100_PQ : CGColorSpace.sRGB)
    }

    /// HDR10 tone-mapping metadata from a frame's mastering-display + content-light SEI attachments; nil when
    /// either is absent (the PQ colorspace then tone-maps with system defaults).
    static func edrMetadata(masteringDisplay: Data?, contentLight: Data?) -> CAEDRMetadata? {
        guard let masteringDisplay, let contentLight else { return nil }
        return .hdr10(displayInfo: masteringDisplay, contentInfo: contentLight, opticalOutputScale: 100)
    }

    /// Update the live HDR state (host `setHdrMode`); the render thread re-tags the layer on the next frame.
    /// Refused on an SDR (non-10-bit) stream, whose layer can't carry PQ.
    public func setHDRActive(_ enabled: Bool) {
        hdrActive.withLock { $0 = enabled && tenBit }
    }

    /// Adaptive display-link rate range: pin to the stream rate, or span stream…displayMax (preferring the
    /// panel's max) when it has real headroom — a decoded frame then flips at the next (shorter) refresh slot.
    public static func frameRateRange(streamFps: Int, displayMaxHz: Int?) -> CAFrameRateRange {
        let target = max(streamFps, 1)
        let maxDisplay = max(displayMaxHz ?? target, target)
        let slackHz = 5
        if maxDisplay > target + slackHz {
            return CAFrameRateRange(minimum: Float(target), maximum: Float(maxDisplay), preferred: Float(maxDisplay))
        }
        return CAFrameRateRange(minimum: Float(target), maximum: Float(target), preferred: Float(target))
    }

    /// Start presentation on a dedicated render thread so main-thread input/UI work can't delay it, and register
    /// for display-reconfiguration callbacks so sleep/lock/wake can't crash CoreAnimation via a live display link.
    public func start() {
        guard renderThread == nil else { return }
        running = true
        registerReconfigurationCallback()
        spawnRenderThread()
    }

    private func spawnRenderThread() {
        let didFinish = DispatchSemaphore(value: 0)
        renderThreadDidFinish = didFinish
        let thread = Thread { [weak self] in
            self?.runDisplayLink()
            didFinish.signal()
        }
        thread.name = "io.github.mozoii.Asteria.present"
        thread.qualityOfService = .userInteractive
        renderThread = thread
        thread.start()
    }

    /// A `CAMetalDisplayLink` fires `draw` just before each scanout, at the panel's max rate when it has
    /// headroom over the stream cadence, so a decoded frame flips at the next (shorter) refresh slot.
    private func runDisplayLink() {
        let link = CAMetalDisplayLink(metalLayer: metalLayer)
        link.delegate = self
        link.preferredFrameLatency = 1.0
        link.preferredFrameRateRange = Self.frameRateRange(streamFps: streamFps, displayMaxHz: displayMaxHz)
        link.add(to: .current, forMode: .common)
        renderRunLoop = CFRunLoopGetCurrent()
        // Run continuously so the vsync source isn't missed in a per-callback re-entry gap.
        while !Thread.current.isCancelled {
            _ = CFRunLoopRunInMode(CFRunLoopMode.defaultMode, 1.0, false)
        }
        link.remove(from: .current, forMode: .common)
        link.delegate = nil
    }

    public func stop() {
        running = false
        unregisterReconfigurationCallback()
        teardownRenderThread()
    }

    /// Cancel the render thread and block until it has removed the display link, so no stale CoreAnimation display
    /// participant survives into a reconfiguration. Bounded: the loop exits within one frame of the cancel.
    private func teardownRenderThread() {
        guard let thread = renderThread else { return }
        thread.cancel()
        if let rl = renderRunLoop { CFRunLoopStop(rl) }
        _ = renderThreadDidFinish?.wait(timeout: .now() + 2)
        renderRunLoop = nil
        renderThread = nil
        renderThreadDidFinish = nil
    }

    /// Tear the present path down while CoreAnimation rebuilds its display registry (sleep/lock/wake), so a live
    /// display link can't crash it; re-spawn on finalize. Runs on the main run loop, sharing state with start/stop.
    fileprivate func handleReconfiguration(_ flags: CGDisplayChangeSummaryFlags) {
        if flags.contains(.beginConfigurationFlag) {
            guard running, !suspendedForReconfig else { return }
            suspendedForReconfig = true
            teardownRenderThread()
        } else if suspendedForReconfig {
            suspendedForReconfig = false
            if running { spawnRenderThread() }
        }
    }

    private func registerReconfigurationCallback() {
        guard !reconfigRegistered else { return }
        CGDisplayRegisterReconfigurationCallback(presenterReconfigurationCallback,
                                                 Unmanaged.passUnretained(self).toOpaque())
        reconfigRegistered = true
    }

    private func unregisterReconfigurationCallback() {
        guard reconfigRegistered else { return }
        CGDisplayRemoveReconfigurationCallback(presenterReconfigurationCallback,
                                               Unmanaged.passUnretained(self).toOpaque())
        reconfigRegistered = false
    }

    public func metalDisplayLink(_ link: CAMetalDisplayLink,
                                 needsUpdate update: CAMetalDisplayLink.Update) {
        // Drain drawables/command buffers per frame: the non-returning CFRunLoopRunInMode below never unwinds to drain them.
        autoreleasepool { draw(update) }
    }

    private func draw(_ update: CAMetalDisplayLink.Update) {
        let entry = CACurrentMediaTime()
        let target = update.targetTimestamp
        // Take the freshest decode ready up to ~1.5ms before scanout (GPU lead) instead of slipping a near-ready frame to the next vsync.
        let wait = (target - entry) - 0.0015
        if wait < 0 { return }
        guard let frame = holder.takeFresh(maxWait: wait), let plan = prepare(frame) else { return }
        applyHDRState(for: frame.buffer)
        // The display link already vended update.drawable; the size takes effect on the next frame.
        setDrawableSize(plan.drawSize)
        encode(plan, into: update.drawable)
    }

    /// Present-path diagnostic logger (render-thread only, single stall line).
    private static let presentLog = Logger(subsystem: "io.github.mozoii.asteria", category: "video-present")

    /// Reconcile the layer to the live HDR state and, once HDR is on, adopt the stream's HDR10 metadata.
    /// Runs on the render thread, so all layer mutation stays where `setDrawableSize` already mutates.
    func applyHDRState(for buffer: CVPixelBuffer) {
        let want = hdrActive.withLock { $0 }
        if want != appliedHDR {
            applyColorTagging(want)
            appliedHDR = want
            if !want { metalLayer.edrMetadata = nil; appliedMasteringData = nil }
        }
        // Mastering SEI may only ride keyframes, so keep looking until it's adopted once.
        guard want, appliedMasteringData == nil else { return }
        let mdcv = CVBufferCopyAttachment(buffer, kCVImageBufferMasteringDisplayColorVolumeKey, nil) as? Data
        let cll = CVBufferCopyAttachment(buffer, kCVImageBufferContentLightLevelInfoKey, nil) as? Data
        guard let meta = Self.edrMetadata(masteringDisplay: mdcv, contentLight: cll) else { return }
        metalLayer.edrMetadata = meta
        appliedMasteringData = mdcv
    }

    /// Re-tag the layer's colorspace + EDR for `on`; batched in a transaction like the drawable-size change.
    private func applyColorTagging(_ on: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        metalLayer.colorspace = Self.layerColorspace(hdr: on)
        metalLayer.wantsExtendedDynamicRangeContent = on
        CATransaction.commit()
    }

    /// Count a present-path failure and log once, so a silent present stall (frames arriving but
    /// nothing presented) is diagnosable from the log instead of a frozen last frame on screen.
    private func notePresentStall(kind: String) {
        if kind == "prepare" { prepareFailures += 1 } else { encodeFailures += 1 }
        guard !presentStallLogged else { return }
        presentStallLogged = true
        let (prepare, encode, presented) = (prepareFailures, encodeFailures, presentedCount)
        Self.presentLog.error("present \(kind) failed (prepare:\(prepare) encode:\(encode) presented:\(presented))")
    }

    /// Wrap the frame's planes and decide the present path (fused single pass vs upscaled two pass) and drawable size.
    private func prepare(_ frame: (buffer: CVPixelBuffer, frameIndex: UInt32)) -> FramePlan? {
        guard let textures = try? YUVFrameTextures(frame.buffer, context: context) else {
            notePresentStall(kind: "prepare")
            return nil
        }
        let width = CVPixelBufferGetWidth(frame.buffer)
        let height = CVPixelBufferGetHeight(frame.buffer)
        let plan = PresentationPlan(frameWidth: width, frameHeight: height,
                                    boundsWidth: metalLayer.bounds.width,
                                    boundsHeight: metalLayer.bounds.height,
                                    contentsScale: metalLayer.contentsScale)
        let upscale = enableMetalFX && plan.upscaleBeneficial && SpatialUpscaler.isSupported(device: context.device)
        // Size the drawable to the presented texture for 1:1 sampling: frame size when fused, upscale target when not.
        let size = upscale ? CGSize(width: plan.targetWidth, height: plan.targetHeight)
                           : CGSize(width: width, height: height)
        return FramePlan(textures: textures, width: width, height: height,
                         presentation: plan, upscale: upscale, drawSize: size)
    }

    /// Encode the chosen path into `drawable` and present. Fused: CSC straight to the drawable (no intermediate).
    /// Upscaled: CSC → intermediate → MetalFX → present pass, since MetalFX needs an RGB input texture.
    private func encode(_ plan: FramePlan, into drawable: CAMetalDrawable) {
        guard let commandBuffer = context.commandQueue.makeCommandBuffer() else {
            notePresentStall(kind: "encode")
            return
        }
        do {
            if plan.upscale {
                guard let source = upscaledSource(plan, in: commandBuffer) else {
                    notePresentStall(kind: "encode")
                    return
                }
                try presentRenderer.encode(source: source, into: drawable.texture, in: commandBuffer)
            } else {
                try fusedRenderer.encode(plan.textures, into: drawable.texture, in: commandBuffer)
            }
        } catch {
            notePresentStall(kind: "encode")
            return
        }
        commandBuffer.present(drawable)
        commandBuffer.commit()
        presentedCount += 1
    }

    /// CSC into the cached intermediate, then MetalFX upscale; the returned texture feeds the present pass.
    private func upscaledSource(_ plan: FramePlan, in commandBuffer: MTLCommandBuffer) -> MTLTexture? {
        if intermediate?.width != plan.width || intermediate?.height != plan.height {
            intermediate = try? renderer.makeOutputTexture(width: plan.width, height: plan.height)
        }
        guard let intermediate else { return nil }
        do {
            try renderer.encode(plan.textures, into: intermediate, in: commandBuffer)
        } catch { return nil }
        return upscaleIfBeneficial(intermediate, frameWidth: plan.width, frameHeight: plan.height,
                                   plan: plan.presentation, in: commandBuffer)
    }

    private func setDrawableSize(_ size: CGSize) {
        guard metalLayer.drawableSize != size else { return }
        // Off-main layer mutation: batch it in an explicit transaction.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        metalLayer.drawableSize = size
        CATransaction.commit()
    }

    /// Upscale if beneficial and supported, else return intermediate unchanged. Scaler and output cached, recreated on dimension change.
    private func upscaleIfBeneficial(_ intermediate: MTLTexture, frameWidth: Int, frameHeight: Int,
                                     plan: PresentationPlan,
                                     in commandBuffer: MTLCommandBuffer) -> MTLTexture {
        guard enableMetalFX, plan.upscaleBeneficial, SpatialUpscaler.isSupported(device: context.device) else {
            upscaler = nil; upscaled = nil; upscalerInput = nil
            return intermediate
        }
        let target = (width: plan.targetWidth, height: plan.targetHeight)
        if upscaler?.outputWidth != target.width || upscaler?.outputHeight != target.height
            || upscalerInput?.width != frameWidth || upscalerInput?.height != frameHeight {
            upscaler = try? SpatialUpscaler(context: context, inputWidth: frameWidth, inputHeight: frameHeight,
                                            outputWidth: target.width, outputHeight: target.height)
            upscalerInput = (frameWidth, frameHeight)
            upscaled = makeUpscaleTexture(width: target.width, height: target.height)
        }
        guard let upscaler, let upscaled else { return intermediate }
        upscaler.encode(input: intermediate, output: upscaled, in: commandBuffer)
        return upscaled
    }

    private func makeUpscaleTexture(width: Int, height: Int) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead, .renderTarget]
        descriptor.storageMode = .private
        return context.device.makeTexture(descriptor: descriptor)
    }

}
