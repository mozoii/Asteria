import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

/// Plays decoded PCM through AVAudioEngine via a lock-free ring and an AVAudioSourceNode; `render` touches only the ring.
public final class CoreAudioRenderer: AudioRenderer, @unchecked Sendable {
    public enum Failure: Error, Equatable { case unsupportedFormat(Int); case noOutputDevice; case engineStartFailed(String) }

    /// Upper bound on a single render slice; sizes the deinterleave scratch (≈341 ms at 48 kHz).
    private static let maxRenderFrames = 16384

    /// Requested output I/O buffer, ≈2.7 ms at 48 kHz vs the ~10.7 ms device default; clamped to the
    /// device's supported range. Smaller buffer → PCM waits less in the ring for the next render callback.
    static let preferredBufferFrames: UInt32 = 128

    let engine = AVAudioEngine()
    let lock = NSLock()
    private var sourceNode: AVAudioSourceNode?
    private var sourceFormat: AVAudioFormat?
    private var ring: PCMRingBuffer?
    private var scratch: UnsafeMutableBufferPointer<Float>?
    private var configObserver: NSObjectProtocol?
    var running = false
    #if os(macOS)
    var appliedBufferFrames: UInt32 = 0
    var bufferSizeListener: AudioObjectPropertyListenerBlock?
    var listenerDevice: AudioDeviceID?
    let bufferSizeQueue = DispatchQueue(label: "CoreAudioRenderer.bufferSize")
    #else
    /// `AVAudioSession` interruption (call, Siri) and route-change observers; interruptions stop the
    /// engine without raising a configuration change, so the engine restart has to be driven from here.
    var sessionObservers: [NSObjectProtocol] = []
    /// Channel count the stream negotiated, re-requested from the session whenever the route changes.
    var requestedChannelCount = 0
    #endif

    public init() {}

    public func start(format: AudioRenderFormat) throws {
        guard let layout = AVAudioChannelLayout(layoutTag: format.layoutTag) else {
            throw Failure.unsupportedFormat(format.channelCount)
        }
        // iOS reports a zero-channel output node until its session is active, so this must precede the preflight.
        try prepareAudioSession(format: format)
        // No output device → connecting throws an uncatchable NSException; pre-flight and bail cleanly instead.
        guard engine.outputNode.outputFormat(forBus: 0).channelCount > 0 else { throw Failure.noOutputDevice }

        // AVAudioEngine node connections require the non-interleaved "standard" float format.
        let sourceFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(format.sampleRate),
                                         interleaved: false, channelLayout: layout)
        let ring = PCMRingBuffer(channelCount: format.channelCount, sampleRate: format.sampleRate)
        let channelCount = format.channelCount
        let scratch = UnsafeMutableBufferPointer<Float>.allocate(capacity: Self.maxRenderFrames * channelCount)
        scratch.initialize(repeating: 0)

        let node = AVAudioSourceNode(format: sourceFormat) { _, _, frameCount, audioBufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let frames = min(Int(frameCount), Self.maxRenderFrames)
            ring.read(into: UnsafeMutableBufferPointer(start: scratch.baseAddress, count: frames * channelCount),
                      count: frames * channelCount)
            for channel in 0..<min(channelCount, buffers.count) {
                guard let destination = buffers[channel].mData?.assumingMemoryBound(to: Float.self) else { continue }
                for frame in 0..<frames { destination[frame] = scratch[frame * channelCount + channel] }
            }
            return noErr
        }

        lock.lock(); defer { lock.unlock() }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: sourceFormat)
        applyPreferredBufferSize()
        do {
            try engine.start()
        } catch {
            engine.detach(node)
            releasePlatformAudio()
            scratch.deallocate()
            throw Failure.engineStartFailed(String(describing: error))
        }
        self.ring = ring
        self.sourceNode = node
        self.sourceFormat = sourceFormat
        self.scratch = scratch
        self.running = true
        // Output device changes stop the engine; rebuild + restart on the configuration-change notification.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            self?.handleConfigurationChange()
        }
    }

    func handleConfigurationChange() {
        lock.lock(); defer { lock.unlock() }
        guard running, let node = sourceNode, let sourceFormat else { return }
        engine.connect(node, to: engine.mainMixerNode, format: sourceFormat)
        applyPreferredBufferSize()
        try? engine.start()
    }

    static func shouldReassertBuffer(current: UInt32, applied: UInt32) -> Bool {
        applied > 0 && current > applied
    }

    static func clampedBufferFrames(target: UInt32, min lo: UInt32, max hi: UInt32) -> UInt32 {
        guard hi >= lo else { return target }
        return Swift.min(Swift.max(target, lo), hi)
    }

    public func render(_ pcm: [Float]) { ring?.write(pcm) }

    /// Silence or restore output without disturbing the decode/render graph; the mixer level persists across restarts.
    public func setMuted(_ muted: Bool) {
        lock.lock(); defer { lock.unlock() }
        engine.mainMixerNode.outputVolume = muted ? 0 : 1
    }

    public func stop() {
        lock.lock(); defer { lock.unlock() }
        running = false
        releasePlatformAudio()
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        engine.stop()
        if let sourceNode { engine.detach(sourceNode) }
        scratch?.deallocate()
        sourceNode = nil
        ring = nil
        sourceFormat = nil
        scratch = nil
    }

    public func renderStats() -> AudioRenderStats { ring?.stats() ?? AudioRenderStats() }
}
