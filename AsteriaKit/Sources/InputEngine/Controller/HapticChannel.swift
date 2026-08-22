import Foundation
@preconcurrency import GameController
@preconcurrency import CoreHaptics

/// One locality's rumble: a continuous player with baked-in intensity, rebuilt only when the value
/// changes past `intensityEpsilon`, so steady rumble and the host's PWM zeros ride a single player.
final class HapticChannel: @unchecked Sendable {
    private let haptics: GCDeviceHaptics
    private let locality: GCHapticsLocality
    private let queue: DispatchQueue
    private let sharpness: Float
    private var engine: CHHapticEngine?
    private var player: CHHapticPatternPlayer?
    /// Intensity currently baked into the running player; -1 when silent.
    private var appliedIntensity: Float = -1
    /// Bumped on every release-schedule and reset; a release whose token is stale is a no-op.
    private var releaseToken: UInt64 = 0
    /// Bumped on every (re)build and stop; a refresh whose token is stale is a no-op.
    private var refreshToken: UInt64 = 0
    /// After a build failure, suppress rebuilds until this time.
    private var retryAfter: DispatchTime = .now()

    /// Event lifetime; a still-active rumble re-arms before it expires. Under CoreHaptics' 30s cap.
    private static let eventDuration: TimeInterval = 8
    private static let refreshInterval: DispatchTimeInterval = .seconds(7)
    private static let intensityEpsilon: Float = 0.02
    /// Hold through a brief zero before silencing, so the host's PWM zeros don't stutter.
    private static let releaseDelay: DispatchTimeInterval = .milliseconds(120)
    private static let failureCooldown: DispatchTimeInterval = .seconds(2)

    init(haptics: GCDeviceHaptics, locality: GCHapticsLocality, queue: DispatchQueue) {
        self.haptics = haptics
        self.locality = locality
        self.queue = queue
        self.sharpness = Self.sharpness(for: locality)
    }

    /// Fixed per actuator: the low handle rumbles deep, the high handle and triggers buzz crisp.
    private static func sharpness(for locality: GCHapticsLocality) -> Float {
        switch locality {
        case .leftHandle: return 0.1
        case .rightHandle: return 0.9
        case .leftTrigger, .rightTrigger: return 0.7
        default: return 0.5
        }
    }

    /// Drive this locality at `value` (0…1). A changed non-zero rebuilds the player; a zero is held
    /// briefly (bridging the host's PWM gap) before silencing.
    func setIntensity(_ value: Float) {
        let v = max(0, min(1, value))
        if v == 0 { scheduleRelease(); return }
        releaseToken &+= 1   // a non-zero cancels any pending release
        if player != nil, abs(v - appliedIntensity) < Self.intensityEpsilon { return }
        play(v)
    }

    /// Silence the player only after a run of zeros outlasts the PWM gap.
    private func scheduleRelease() {
        releaseToken &+= 1
        let token = releaseToken
        queue.asyncAfter(deadline: .now() + Self.releaseDelay) { [weak self] in
            guard let self, self.releaseToken == token else { return }
            self.stopPlayer()
        }
    }

    /// (Re)build and start a player with `intensity` baked in. On failure tear the engine down and
    /// leave it on cooldown, so the next attempt uses a fresh engine, not a wedged one.
    private func play(_ intensity: Float) {
        if DispatchTime.now() < retryAfter { return }
        guard let engine = ensureEngine(),
              let player = makePlayer(on: engine, intensity: intensity) else {
            teardown(clearReset: false)
            retryAfter = .now() + Self.failureCooldown
            return
        }
        stopPlayer()
        guard (try? player.start(atTime: 0)) != nil else { return }
        self.player = player
        appliedIntensity = intensity
        scheduleRefresh()
    }

    /// Re-arm the event before it expires while the rumble is still active.
    private func scheduleRefresh() {
        refreshToken &+= 1
        let token = refreshToken
        queue.asyncAfter(deadline: .now() + Self.refreshInterval) { [weak self] in
            guard let self, self.refreshToken == token, self.appliedIntensity > 0 else { return }
            self.play(self.appliedIntensity)
        }
    }

    private func ensureEngine() -> CHHapticEngine? {
        if let engine { return engine }
        guard let engine = haptics.createEngine(withLocality: locality) else { return nil }
        engine.isAutoShutdownEnabled = false
        // Reset fires on CoreHaptics' own thread; tear down and rebuild lazily on the next command.
        engine.resetHandler = { [weak self] in
            guard let self else { return }
            self.queue.async { self.teardown(clearReset: false) }
        }
        do { try engine.start() } catch { return nil }
        self.engine = engine
        return engine
    }

    /// A continuous player with `intensity` and the locality's sharpness baked in.
    private func makePlayer(on engine: CHHapticEngine, intensity: Float) -> CHHapticPatternPlayer? {
        let ip = CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity)
        let sp = CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness)
        let event = CHHapticEvent(eventType: .hapticContinuous, parameters: [ip, sp],
                                  relativeTime: 0, duration: Self.eventDuration)
        guard let pattern = try? CHHapticPattern(events: [event], parameters: []) else {
            return nil
        }
        return try? engine.makePlayer(with: pattern)
    }

    private func stopPlayer() {
        refreshToken &+= 1
        try? player?.stop(atTime: 0)
        player = nil
        appliedIntensity = -1
    }

    /// Release the engine (dealloc is quiet; an explicit `stop()` with a live player logs a benign
    /// `_player != nil` warning). `clearReset` detaches the handler for permanent teardown.
    private func teardown(clearReset: Bool) {
        releaseToken &+= 1
        if clearReset { engine?.resetHandler = {} }
        stopPlayer()
        engine = nil
    }

    func invalidate() { teardown(clearReset: true) }
}

/// Haptic channels per locality for one controller.
final class SlotHaptics {
    private let device: GCDeviceHaptics
    private let queue: DispatchQueue
    private var channels: [GCHapticsLocality: HapticChannel] = [:]

    init(device: GCDeviceHaptics, queue: DispatchQueue) {
        self.device = device
        self.queue = queue
    }

    /// Whether the controller has separate left/right handles.
    var supportsSplitHandles: Bool {
        device.supportedLocalities.contains(.leftHandle) && device.supportedLocalities.contains(.rightHandle)
    }

    func channel(_ locality: GCHapticsLocality) -> HapticChannel? {
        if let existing = channels[locality] { return existing }
        guard device.supportedLocalities.contains(locality) else { return nil }
        let channel = HapticChannel(haptics: device, locality: locality, queue: queue)
        channels[locality] = channel
        return channel
    }

    /// Tear down one locality's engine, e.g. between debug-sweep steps so engines never pile up.
    func release(_ locality: GCHapticsLocality) {
        channels[locality]?.invalidate()
        channels[locality] = nil
    }

    func invalidate() {
        channels.values.forEach { $0.invalidate() }
        channels.removeAll()
    }
}
