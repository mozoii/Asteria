#if os(iOS)
import AVFoundation
import Foundation

/// iOS output sizing: there is no HAL to address, so the I/O buffer, sample rate and channel count are
/// requested through `AVAudioSession`. The session must be active before `AVAudioEngine.outputNode`
/// reports a usable format, so activation happens ahead of the renderer's output preflight.
extension CoreAudioRenderer {
    /// `.playback` ignores the ring/silent switch, which is what a game stream wants, and keeps the
    /// stream audible with the screen dimmed. Preferred buffer duration is the analogue of the Mac's
    /// `preferredBufferFrames`; the system clamps it to whatever the current route can honor.
    func prepareAudioSession(format: AudioRenderFormat) throws {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default)
            try session.setPreferredSampleRate(Double(format.sampleRate))
            try session.setPreferredIOBufferDuration(
                Double(Self.preferredBufferFrames) / Double(format.sampleRate))
            try session.setActive(true)
        } catch {
            throw Failure.engineStartFailed("audio session: \(error.localizedDescription)")
        }
        requestedChannelCount = format.channelCount
        applyPreferredOutputChannels()
        observeSessionChanges()
    }

    /// Ask the active route for the stream's channel count, clamped to what it can carry. A stereo route
    /// keeps 2 and `AVAudioEngine` downmixes surround into it, matching the Mac behavior.
    func applyPreferredOutputChannels() {
        let session = AVAudioSession.sharedInstance()
        guard requestedChannelCount > 0 else { return }
        let channels = min(requestedChannelCount, session.maximumOutputNumberOfChannels)
        try? session.setPreferredOutputNumberOfChannels(channels)
    }

    /// Re-request the preferred buffer duration after a route change; the session resets it per route.
    func applyPreferredBufferSize() {
        let session = AVAudioSession.sharedInstance()
        let sampleRate = session.sampleRate > 0 ? session.sampleRate : 48_000
        try? session.setPreferredIOBufferDuration(Double(Self.preferredBufferFrames) / sampleRate)
    }

    /// Interruptions stop the engine without a configuration change, so the resume has to be driven here.
    /// Route changes do raise `.AVAudioEngineConfigurationChange`, but only the session knows the new
    /// channel capacity, so the preferred count is re-requested before the engine rebuilds its graph.
    private func observeSessionChanges() {
        guard sessionObservers.isEmpty else { return }
        let center = NotificationCenter.default
        let interruption = center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(), queue: nil) { [weak self] note in
            self?.handleInterruption(note)
        }
        let routeChange = center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(), queue: nil) { [weak self] _ in
            self?.applyPreferredOutputChannels()
        }
        sessionObservers = [interruption, routeChange]
    }

    private func handleInterruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            break   // the system has already stopped the engine; the ring keeps filling and is read on resume
        case .ended:
            let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt)
                .map(AVAudioSession.InterruptionOptions.init(rawValue:)) ?? []
            guard options.contains(.shouldResume) else { return }
            try? AVAudioSession.sharedInstance().setActive(true)
            handleConfigurationChange()
        @unknown default:
            break
        }
    }

    /// Drop the session observers and hand the route back, so other apps resume when the stream ends.
    func releasePlatformAudio() {
        for observer in sessionObservers { NotificationCenter.default.removeObserver(observer) }
        sessionObservers = []
        requestedChannelCount = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
#endif
