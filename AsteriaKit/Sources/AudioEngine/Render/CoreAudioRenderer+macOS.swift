#if os(macOS)
import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

/// macOS output sizing: the HAL exposes the device's I/O buffer directly, so the renderer shrinks it
/// toward `preferredBufferFrames` and defends that size against other clients enlarging it.
extension CoreAudioRenderer {
    /// No session to configure: the HAL routes to the current default device without one.
    func prepareAudioSession(format: AudioRenderFormat) throws {}

    /// Drop the buffer-size listener and forget the applied size, so a restart re-negotiates from scratch.
    func releasePlatformAudio() {
        removeBufferSizeListener()
        appliedBufferFrames = 0
    }

    /// Shrink the output device's I/O buffer toward `preferredBufferFrames`, clamped to its range.
    /// `…BufferFrameSize` is device-global and last-writer-wins, so `observeBufferFrameSize` defends it.
    func applyPreferredBufferSize() {
        guard let device = currentOutputDevice(), let range = bufferFrameSizeRange(of: device) else { return }
        var frames = Self.clampedBufferFrames(target: Self.preferredBufferFrames,
                                              min: UInt32(range.mMinimum), max: UInt32(range.mMaximum))
        var addr = Self.bufferFrameSizeAddress
        AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &frames)
        appliedBufferFrames = bufferFrameSize(of: device) ?? frames
        observeBufferFrameSize(on: device)
    }

    static let bufferFrameSizeAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyBufferFrameSize, mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    func currentOutputDevice() -> AudioDeviceID? {
        guard let unit = engine.outputNode.audioUnit else { return nil }
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                   kAudioUnitScope_Global, 0, &device, &size) == noErr, device != 0 else { return nil }
        return device
    }

    func bufferFrameSizeRange(of device: AudioDeviceID) -> AudioValueRange? {
        var range = AudioValueRange()
        var size = UInt32(MemoryLayout<AudioValueRange>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyBufferFrameSizeRange,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &range) == noErr else { return nil }
        return range
    }

    func bufferFrameSize(of device: AudioDeviceID) -> UInt32? {
        var frames = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = Self.bufferFrameSizeAddress
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &frames) == noErr else { return nil }
        return frames
    }

    /// Watch for another client enlarging the shared buffer and re-apply our size. The callback runs on a
    /// private queue and tries the lock, so teardown never deadlocks against an in-flight notification.
    func observeBufferFrameSize(on device: AudioDeviceID) {
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

    func removeBufferSizeListener() {
        guard let device = listenerDevice, let block = bufferSizeListener else { return }
        var addr = Self.bufferFrameSizeAddress
        AudioObjectRemovePropertyListenerBlock(device, &addr, bufferSizeQueue, block)
        bufferSizeListener = nil
        listenerDevice = nil
    }

    func reassertBufferFrameSize(on device: AudioDeviceID) {
        guard lock.try() else { return }   // best-effort; skip while start/stop/config holds the lock
        defer { lock.unlock() }
        guard running, listenerDevice == device, let current = bufferFrameSize(of: device),
              Self.shouldReassertBuffer(current: current, applied: appliedBufferFrames) else { return }
        var frames = appliedBufferFrames
        var addr = Self.bufferFrameSizeAddress
        AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &frames)
    }

}
#endif
