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

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var sourceNode: AVAudioSourceNode?
    private var sourceFormat: AVAudioFormat?
    private var ring: PCMRingBuffer?
    private var scratch: UnsafeMutableBufferPointer<Float>?
    private var configObserver: NSObjectProtocol?
    private var running = false
    private var appliedBufferFrames: UInt32 = 0
    private var bufferSizeListener: AudioObjectPropertyListenerBlock?
    private var listenerDevice: AudioDeviceID?
    private let bufferSizeQueue = DispatchQueue(label: "CoreAudioRenderer.bufferSize")

    public init() {}

    public func start(format: AudioRenderFormat) throws {
        guard let layout = AVAudioChannelLayout(layoutTag: format.layoutTag) else {
            throw Failure.unsupportedFormat(format.channelCount)
        }
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
            removeBufferSizeListener()
            appliedBufferFrames = 0
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

    private func handleConfigurationChange() {
        lock.lock(); defer { lock.unlock() }
        guard running, let node = sourceNode, let sourceFormat else { return }
        engine.connect(node, to: engine.mainMixerNode, format: sourceFormat)
        applyPreferredBufferSize()
        try? engine.start()
    }

    /// Shrink the output device's I/O buffer toward `preferredBufferFrames`, clamped to its range.
    /// `…BufferFrameSize` is device-global and last-writer-wins, so `observeBufferFrameSize` defends it.
    private func applyPreferredBufferSize() {
        guard let device = currentOutputDevice(), let range = bufferFrameSizeRange(of: device) else { return }
        var frames = Self.clampedBufferFrames(target: Self.preferredBufferFrames,
                                              min: UInt32(range.mMinimum), max: UInt32(range.mMaximum))
        var addr = Self.bufferFrameSizeAddress
        AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &frames)
        appliedBufferFrames = bufferFrameSize(of: device) ?? frames
        observeBufferFrameSize(on: device)
    }

    private static let bufferFrameSizeAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyBufferFrameSize, mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    private func currentOutputDevice() -> AudioDeviceID? {
        guard let unit = engine.outputNode.audioUnit else { return nil }
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                   kAudioUnitScope_Global, 0, &device, &size) == noErr, device != 0 else { return nil }
        return device
    }

    private func bufferFrameSizeRange(of device: AudioDeviceID) -> AudioValueRange? {
        var range = AudioValueRange()
        var size = UInt32(MemoryLayout<AudioValueRange>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyBufferFrameSizeRange,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &range) == noErr else { return nil }
        return range
    }

    private func bufferFrameSize(of device: AudioDeviceID) -> UInt32? {
        var frames = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = Self.bufferFrameSizeAddress
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &frames) == noErr else { return nil }
        return frames
    }

    /// Watch for another client enlarging the shared buffer and re-apply our size. The callback runs on a
    /// private queue and tries the lock, so teardown never deadlocks against an in-flight notification.
    private func observeBufferFrameSize(on device: AudioDeviceID) {
        guard listenerDevice != device else { return }
        removeBufferSizeListener()
        var addr = Self.bufferFrameSizeAddress
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.reassertBufferFrameSize(on: device)
        }
        guard AudioObjectAddPropertyListenerBlock(device, &addr, bufferSizeQueue, block) == noErr else { return }
        bufferSizeListener = block
        listenerDevice = device
    }

    private func removeBufferSizeListener() {
        guard let device = listenerDevice, let block = bufferSizeListener else { return }
        var addr = Self.bufferFrameSizeAddress
        AudioObjectRemovePropertyListenerBlock(device, &addr, bufferSizeQueue, block)
        bufferSizeListener = nil
        listenerDevice = nil
    }

    private func reassertBufferFrameSize(on device: AudioDeviceID) {
        guard lock.try() else { return }   // best-effort; skip while start/stop/config holds the lock
        defer { lock.unlock() }
        guard running, listenerDevice == device, let current = bufferFrameSize(of: device),
              Self.shouldReassertBuffer(current: current, applied: appliedBufferFrames) else { return }
        var frames = appliedBufferFrames
        var addr = Self.bufferFrameSizeAddress
        AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &frames)
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
        removeBufferSizeListener()
        appliedBufferFrames = 0
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
