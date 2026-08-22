import Foundation
import AppKit
import SwiftUI
import Observation
import os
import QuartzCore
import AsteriaKit

/// On-screen video sink: an app-side adapter over VideoEngine's `VideoPresentation`; main-confined.
@MainActor
final class PresenterVideoSink: VideoSink {
    private(set) var presentation: VideoPresentation?
    var metalLayer: CAMetalLayer? { presentation?.metalLayer }
    private let size: CGSize
    private let options: PresentOptions

    init(size: CGSize, options: PresentOptions) {
        self.size = size
        self.options = options
    }

    func makeRenderer(for videoFormat: VideoFormat) async -> DecoderRenderer? {
        guard let presentation = VideoPresentation(videoFormat: videoFormat, initialSize: size,
                                                   options: options) else { return nil }
        presentation.start()
        self.presentation = presentation
        return presentation.decoderRenderer
    }

    var deliveredCount: Int { presentation?.deliveredCount ?? 0 }
    var presentedCount: Int { presentation?.presentedCount ?? 0 }
    var meanDecodeMillis: Double { presentation?.meanDecodeMillis ?? 0 }
    func stop() { presentation?.stop() }
}

/// Drives one live stream for a chosen host + app: builds the pinned transport from the Keychain identity and
/// the host's pinned cert, assembles the wire config from settings ∩ caps, and routes local hotkeys to the shell.
@MainActor
@Observable
final class StreamController {
    typealias Phase = ConnectionStateMachine.Phase

    /// Connection lifecycle policy; this controller is its effect-performing adapter.
    private var machine = ConnectionStateMachine()
    var phase: Phase { machine.phase }
    private(set) var videoLayer: CAMetalLayer?
    private(set) var streamPixelSize: PixelSize?
    var showStats = false
    /// Chord-triggered overlay menu; opening it releases input so the menu is usable.
    private(set) var showMenu = false
    /// Highlighted menu row, driven by arrow keys / d-pad.
    private(set) var menuSelection = 0
    private(set) var mouseMode: MouseMode
    /// A /resume connected but never delivered video; the user is prompted to quit + relaunch.
    var resumeStalled: Bool { machine.resumeStalled }

    let title: String
    let startFullscreen: Bool
    let hideTitleBarInWindowedMode: Bool

    /// App-side input capture: cursor hide/dissociate, key-beep swallowing, focus-driven release.
    let inputCapture = StreamInputCapture()

    /// Shell-handled hotkeys the engine doesn't consume itself (e.g. toggle full screen).
    var onToggleFullscreen: () -> Void = {}

    private(set) var decodedFrames = 0
    private var lastSnapshotDecodedFrames = 0
    private(set) var fps = 0
    private(set) var presentedFrames = 0
    private(set) var lostFrames = 0
    private(set) var recoveryRequests = 0
    private(set) var rttMillis = 0
    private(set) var bitrateMbps = 0.0
    private(set) var decodeMillis = 0.0
    /// Mean local input enqueue→flush latency (ms) — the "Input" half of the E2E overlay line.
    private(set) var inputMillis = 0.0
    private(set) var lossPercent = 0.0
    /// Negotiated stream geometry, shown in the HUD; populated once the plan is built.
    private(set) var streamResolution = ""
    /// Whether the stream is presenting HDR now (initial negotiation, then live host `setHdrMode`); drives the HUD.
    private(set) var hdrActive = false
    /// Negotiated bit depth, so a live HDR toggle mirrors the presenter's 10-bit-only gate.
    private var streamIsTenBit = false
    /// Local Mac telemetry shown automatically in the stats HUD.
    private(set) var laptopStats = LaptopStats.unavailable
    private var powerUsageMeter = PowerUsageMeter()
    private(set) var powerUsageHigh = false

    var statsModel: StatsHUDModel {
        var model = StatsHUDModel(resolution: streamResolution, fps: fps, rttMillis: rttMillis,
                                  lossPercent: lossPercent, bitrateMbps: bitrateMbps,
                                  decodeMillis: decodeMillis, inputMillis: inputMillis,
                                   metalFX: settings.enableMetalFX, hdr: hdrActive,
                                  adaptiveMode: adaptiveActive ? adaptiveMode : nil,
                                  showNetworkLatency: overlayPreferences.showNetworkLatency,
                                  showInputLatency: overlayPreferences.showInputLatency,
                                  showDecodeLatency: overlayPreferences.showDecodeLatency)
        model.laptopStats = laptopStats
        model.powerUsageHigh = powerUsageHigh
        return model
    }
    private let host: HostRecord
    private let appId: String
    private let settings: StreamSettings
    private let capabilities: StreamCapabilities
    private let inputPreferences: InputPreferences
    private let overlayPreferences: OverlayPreferences
    private var localPowerTelemetry = LocalPowerTelemetry()
    private let identities: ClientIdentityVault
    private let clipboard: any ClipboardSource

    /// True while the Live Stream Session is driving host bitrate changes.
    private(set) var adaptiveActive = false
    /// Current aggressiveness, shown and cycled in the overlay menu.
    private(set) var adaptiveMode: AdaptiveMode

    private(set) var currentToast: StreamToast?
    private var toastQueue = StreamToastQueue()
    private var toastTask: Task<Void, Never>?
    private let notificationsAllowed: Bool

    private var streamSession: LiveStreamSession?
    private var videoSink: PresenterVideoSink?
    /// Held so app-active changes can mute/unmute it when `settings.muteWhenInactive` is on.
    private var audioRenderer: CoreAudioRenderer?
    /// Manual mute toggled by the in-stream bind or overlay menu; independent of inactive-muting.
    private(set) var audioMuted = false
    /// App activate/resignActive observers driving inactive-muting; empty when the feature is off.
    private var activeObservers: [NSObjectProtocol] = []
    private var eventsTask: Task<Void, Never>?
    private var statsTask: Task<Void, Never>?
    /// Serializes capture requests: independent `Task`s racing to the session could otherwise land the
    /// final `setInputCapture(false)`/`(true)` out of order and strand input gated off.
    private var captureTask: Task<Void, Never>?
    private var captureRequests: AsyncStream<Bool>.Continuation?
    private static let statsLog = Logger(subsystem: "io.github.mozoii.asteria", category: "telemetry")

    init(host: HostRecord, entry: AppLibraryEntry, settings: StreamSettings,
         capabilities: StreamCapabilities, inputPreferences: InputPreferences,
         overlayPreferences: OverlayPreferences = .defaults,
         notificationsAllowed: Bool = true,
         identities: ClientIdentityVault = .appKeychain,
         clipboard: any ClipboardSource = SystemClipboard()) {
        self.host = host
        self.clipboard = clipboard
        self.appId = entry.appId
        self.title = entry.title
        self.settings = settings
        self.capabilities = capabilities
        self.inputPreferences = inputPreferences
        self.overlayPreferences = overlayPreferences
        self.notificationsAllowed = notificationsAllowed
        self.identities = identities
        self.startFullscreen = settings.windowMode == .windowedFullscreen
        self.hideTitleBarInWindowedMode = settings.windowMode == .windowed
            && settings.hideTitleBarInWindowedMode
        self.mouseMode = inputPreferences.mouseMode
        self.adaptiveMode = settings.adaptiveMode
    }

    /// Negotiate, assemble, and drive the connection lifecycle to streaming (or a setup failure).
    func connect() async { await apply(.connectRequested) }

    /// Reconnect after an unexpected drop (overlay button). With quit-and-relaunch this restarts the game.
    func reconnect() { Task { await connect() } }

    /// Quit the host game and reconnect as a fresh launch. The stalled session is still live
    /// (machine in `.streaming`), so the machine tears it down before re-attempting.
    func relaunchAfterStalledResume() {
        Task { await apply(.relaunchRequested) }
    }

    /// Dismiss the stalled-resume prompt without acting (leaves the resumed session running).
    func dismissStalledResume() {
        Task { await apply(.resumeStalledDismissed) }
    }

    /// User explicitly ends/quits: tear down and return to the library, no reconnect overlay.
    /// With "close app on disconnect" enabled, also quit the running app on the host.
    func disconnect() async {
        let session = streamSession
        await apply(.userEnded)
        if settings.closeAppOnDisconnect, let session {
            _ = try? await session.cancel()
        }
    }

    /// Feed one lifecycle event through the policy, then perform whatever effects it returns.
    private func apply(_ event: ConnectionStateMachine.Event) async {
        for effect in machine.receive(event) { await perform(effect) }
    }

    private func perform(_ effect: ConnectionStateMachine.Effect) async {
        switch effect {
        case let .beginAttempt(forceLaunch):
            await beginAttempt(forceLaunch: forceLaunch)
        case .tearDown:
            await teardownSession()
        case let .scheduleRetry(afterMillis):
            try? await Task.sleep(nanoseconds: UInt64(afterMillis) * 1_000_000)
            await apply(.retryTimerFired)
        }
    }

    /// Build the pinned transport + wire config, open the session, and report the outcome back as an event.
    private func beginAttempt(forceLaunch: Bool) async {
        powerUsageMeter.reset()
        localPowerTelemetry.reset()
        lastSnapshotDecodedFrames = 0
        laptopStats = .unavailable
        powerUsageHigh = false
        do {
            let plan = StreamConfigBuilder.plan(appId: appId, settings: settings, capabilities: capabilities)
            let size = CGSize(width: plan.configuration.width, height: plan.configuration.height)
            streamPixelSize = PixelSize(width: plan.configuration.width,
                                        height: plan.configuration.height)
            streamResolution = "\(plan.configuration.width)×\(plan.configuration.height)"
            // Live per-stream query, not the launch-time NSScreen.main probe: that snapshots whichever
            // screen had focus (a 120 Hz secondary caps a 240 Hz panel). The link clamps to the hosting display.
            let displayMaxHz = NSScreen.screens.map(\.maximumFramesPerSecond).max()
            let sink = PresenterVideoSink(
                size: size,
                options: PresentOptions(streamFps: plan.configuration.fps, displayMaxHz: displayMaxHz,
                                        enableMetalFX: plan.enableMetalFX, hdr: plan.configuration.hdr))
            let renderer = CoreAudioRenderer()
            let stream = try await LiveStreamSession.connect(
                profile: host, identities: identities, settings: settings, plan: plan,
                videoSink: sink, audioRenderer: renderer,
                inputSurface: inputCapture.surface, captureSystemKeys: true,
                inputPreferences: inputPreferences, forceLaunch: forceLaunch,
                presentationMetrics: { @MainActor [weak sink] in
                    LivePresentationMetrics(
                        deliveredFrames: sink?.deliveredCount ?? 0,
                        presentedFrames: sink?.presentedCount ?? 0,
                        meanDecodeMillis: sink?.meanDecodeMillis ?? 0
                    )
                },
                clipboardSnapshot: { @MainActor [clipboard] in
                    LiveClipboardSnapshot(
                        changeCount: clipboard.changeCount,
                        text: clipboard.string()
                    )
                })
            self.videoSink = sink
            self.streamSession = stream
            streamIsTenBit = stream.videoFormat.isTenBit
            hdrActive = plan.configuration.hdr && streamIsTenBit
            self.audioRenderer = renderer
            startInactiveMutingIfEnabled()
            self.videoLayer = sink.metalLayer
            let (requests, continuation) = AsyncStream<Bool>.makeStream()
            captureRequests = continuation
            inputCapture.onInputStateRequest = { continuation.yield($0) }
            captureTask = Task { for await active in requests { await stream.setInputCapture(active) } }

            eventsTask = Task { [weak self] in
                for await intent in stream.intents {
                    switch intent {
                    case let .lifecycle(event):
                        await self?.apply(event)
                    case let .command(action):
                        self?.handle(action)
                    case let .menuNavigation(navigation):
                        self?.handleMenuNav(navigation)
                    case let .hdrModeChanged(enabled):
                        self?.applyHDRMode(enabled)
                    case let .runtimeSnapshot(snapshot):
                        self?.applyRuntimeSnapshot(snapshot)
                    case let .notification(message):
                        self?.showAbrToast(message)
                    case let .adaptiveModeChanged(mode):
                        self?.adaptiveMode = mode
                    }
                }
            }
            startLocalPowerPolling()

            do {
                try await stream.start()
                inputCapture.inputSink = await stream.localInput
                await apply(.streamLive)
            } catch {
                await apply(.setupFailed(message: Self.startFailureMessage(error)))
            }
        } catch {
            await apply(.setupFailed(message: Self.message(for: error)))
        }
    }

    /// When inactive-muting is enabled, observe app activation and silence stream audio while Asteria isn't frontmost.
    private func startInactiveMutingIfEnabled() {
        guard settings.muteWhenInactive else { return }
        let nc = NotificationCenter.default
        activeObservers = [
            nc.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) {
                [weak self] _ in
                Task { @MainActor in self?.applyAudioMute() }
            },
            nc.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) {
                [weak self] _ in
                Task { @MainActor in self?.applyAudioMute() }
            },
        ]
        applyAudioMute()   // honor the current state immediately
    }

    /// Manual mute + inactive-mute combine: either keeps the renderer silent.
    func applyAudioMute() {
        let muted = audioMuted || (settings.muteWhenInactive && !NSApp.isActive)
        audioRenderer?.setMuted(muted)
    }

    /// Toggle manual stream-audio mute; no-op when audio plays on the host (nothing local to mute).
    func toggleAudioMute() {
        guard !settings.playAudioOnHost else { return }
        audioMuted.toggle()
        applyAudioMute()
        showToast(StreamToast(
            category: audioMuted ? .audioMuted : .audioUnmuted,
            message: audioMuted ? "Audio muted" : "Audio unmuted"))
    }

    private func stopInactiveMuting() {
        activeObservers.forEach(NotificationCenter.default.removeObserver)
        activeObservers.removeAll()
    }

    /// Stops the local session and releases app resources without deciding the next phase (the host session keeps
    /// running). Idempotent via capture-before-await; teardown ordering and the 10 s bound live in `LiveStreamSession.stop`.
    private func teardownSession() async {
        stopInactiveMuting()
        guard let session = streamSession else { return }
        streamSession = nil
        let tele = await session.telemetry
        let summary = Self.summaryLine(telemetry: tele,
                                       presented: videoSink?.presentedCount ?? 0,
                                       delivered: videoSink?.deliveredCount ?? 0)
        Self.statsLog.notice("stream summary: \(summary)")
        await session.stop()
        inputCapture.onInputStateRequest = nil
        inputCapture.inputSink = nil
        captureRequests?.finish(); captureRequests = nil
        inputCapture.restoreCursor()
        eventsTask?.cancel(); eventsTask = nil
        hdrActive = false; streamIsTenBit = false
        powerUsageMeter.reset()
        localPowerTelemetry.reset()
        laptopStats = .unavailable
        powerUsageHigh = false
        captureTask?.cancel(); captureTask = nil
        statsTask?.cancel(); statsTask = nil
        clearToasts()
        audioMuted = false
        adaptiveActive = false
        videoSink?.stop()
        videoSink = nil
        audioRenderer = nil
        videoLayer = nil
        showMenu = false
    }

    /// Self-diagnostic teardown line: standard telemetry + control breakdown + presenter counts +
    /// how long ago video last had activity (a large age at teardown is the freeze signature).
    private static func summaryLine(telemetry tele: StreamTelemetry, presented: Int, delivered: Int) -> String {
        let lastActivity = tele.videoTransport.lastActivityNanos.map { last in
            let now = DispatchTime.now().uptimeNanoseconds
            let ageSeconds = now >= last ? (now - last) / 1_000_000_000 : 0
            return "video last active \(ageSeconds)s ago"
        } ?? "no video activity"
        return "\(String(describing: tele)) · control \(tele.control) · presented \(presented)/\(delivered)delivered · \(lastActivity)"
    }

    /// Apply a host `setHdrMode`: re-tag the present layer and mirror the state in the HUD (10-bit streams only).
    private func applyHDRMode(_ enabled: Bool) {
        videoSink?.presentation?.setHDRActive(enabled)
        hdrActive = enabled && streamIsTenBit
    }

    /// Apply a local hotkey action the engine surfaced; capture toggle + mouse-mode flip happen in the engine.
    private func handle(_ action: StreamAction) {
        switch action {
        case .toggleOverlayMenu: toggleMenu()
        case .endStream: Task { await disconnect() }
        case .toggleStats: showStats.toggle()
        case .toggleFullscreen: onToggleFullscreen()
        case .toggleMouseMode: mouseMode = flipped(mouseMode)
        case .toggleInputCapture: break
        case .toggleMute: toggleAudioMute()
        }
    }

    /// Ask the Live Stream Session to change adaptive aggressiveness.
    func setAdaptiveMode(_ mode: AdaptiveMode) {
        guard mode != adaptiveMode else { return }
        let session = streamSession
        Task { _ = await session?.setAdaptiveMode(mode) }
    }

    func showToast(_ toast: StreamToast) {
        let policy = StreamNotificationPolicy(
            systemAllowed: notificationsAllowed,
            adaptiveBitrateAllowed: overlayPreferences.showAdaptiveBitrateNotifications,
            muteAllowed: overlayPreferences.showMuteNotifications)
        guard policy.allows(toast.category) else { return }
        let wasEmpty = toastQueue.current == nil
        guard toastQueue.enqueue(toast) else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            currentToast = toastQueue.current
        }
        if wasEmpty { scheduleToastDismissal() }
    }

    private func showAbrToast(_ message: String) {
        showToast(StreamToast(category: .adaptiveBitrate, message: message))
    }

    private func scheduleToastDismissal() {
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, let self else { return }
            _ = self.toastQueue.dismissCurrent()
            withAnimation(.easeInOut(duration: 0.2)) {
                self.currentToast = self.toastQueue.current
            }
            if self.currentToast != nil { self.scheduleToastDismissal() }
        }
    }

    private func clearToasts() {
        toastTask?.cancel(); toastTask = nil
        toastQueue.clear()
        currentToast = nil
    }

    private func cycleAdaptiveMode() {
        let modes = AdaptiveMode.allCases
        let next = modes[(modes.firstIndex(of: adaptiveMode).map { $0 + 1 } ?? 0) % modes.count]
        setAdaptiveMode(next)
    }

    private func flipped(_ mode: MouseMode) -> MouseMode { mode == .game ? .desktop : .game }

    /// One row of the overlay menu; `prominent` styles the primary (Resume) action.
    struct MenuItem: Identifiable {
        let id: String
        let title: String
        let icon: String
        var prominent = false
        let action: () -> Void
    }

    var menuItems: [MenuItem] {
        var items = [
            MenuItem(id: "resume", title: "Resume", icon: "play.fill", prominent: true) { [weak self] in self?.closeMenu() },
            MenuItem(id: "mouse", title: "Mouse mode: \(mouseMode.displayName)", icon: "cursorarrow.motionlines") { [weak self] in self?.flipMouseMode() },
            MenuItem(id: "stats", title: showStats ? "Hide stats" : "Show stats", icon: "speedometer") { [weak self] in self?.showStats.toggle() },
            MenuItem(id: "quit", title: "Quit app on host", icon: "stop.circle") { [weak self] in self?.quitGameOnHost() },
            MenuItem(id: "end", title: "End stream", icon: "xmark.circle.fill") { [weak self] in self?.endStream() },
        ]
        if !settings.playAudioOnHost {
            items.insert(MenuItem(id: "mute", title: audioMuted ? "Unmute audio" : "Mute audio",
                                  icon: audioMuted ? "speaker.slash.fill" : "speaker.wave.2.fill") { [weak self] in
                self?.toggleAudioMute()
            }, at: 3)
        }
        if adaptiveActive {
            items.insert(MenuItem(id: "adaptive", title: "Adaptive: \(adaptiveMode.displayName)", icon: "gauge.with.dots.needle.bottom.50percent") { [weak self] in
                self?.cycleAdaptiveMode()
            }, at: 3)
        }
        #if DEBUG
        items.insert(MenuItem(id: "rumble", title: "Test rumble", icon: "waveform") { [weak self] in
            self?.fireTestRumble()
        }, at: items.count - 1)
        #endif
        return items
    }

    #if DEBUG
    private func fireTestRumble() {
        let session = streamSession
        closeMenu()
        Task { await session?.fireTestRumble() }
    }
    #endif

    func toggleMenu() { showMenu ? closeMenu() : openMenu() }

    func openMenu() {
        menuSelection = 0
        showMenu = true
        inputCapture.requestInputState(active: false)
        let session = streamSession
        Task { await session?.setMenuOpen(true) }
    }

    func closeMenu() {
        showMenu = false
        inputCapture.requestInputState(active: true)
        let session = streamSession
        Task { await session?.setMenuOpen(false) }
    }

    func handleMenuNav(_ nav: MenuNav) {
        guard showMenu else { return }
        let items = menuItems
        switch nav {
        case .up: menuSelection = max(0, menuSelection - 1)
        case .down: menuSelection = min(items.count - 1, menuSelection + 1)
        case .select: if items.indices.contains(menuSelection) { items[menuSelection].action() }
        case .back: closeMenu()
        }
    }

    func quitGameOnHost() {
        let session = streamSession
        Task {
            await disconnect()
            if let session { _ = try? await session.cancel() }
        }
    }

    func endStream() { Task { await disconnect() } }

    func flipMouseMode() {
        let session = streamSession
        Task { await session?.toggleMouseMode() }
    }

    private func applyRuntimeSnapshot(_ snapshot: LiveRuntimeSnapshot) {
        let telemetry = snapshot.telemetry
        decodedFrames = snapshot.presentation.deliveredFrames
        fps = max(0, decodedFrames - lastSnapshotDecodedFrames)
        lastSnapshotDecodedFrames = decodedFrames
        presentedFrames = snapshot.presentation.presentedFrames
        decodeMillis = snapshot.presentation.meanDecodeMillis
        lostFrames = telemetry.decode.networkLost
        recoveryRequests = telemetry.decode.idrRequests
        lossPercent = telemetry.decode.lossRate * 100
        rttMillis = Int(telemetry.controlRoundTripMillis)
        inputMillis = telemetry.input.averageLatencyMillis
        bitrateMbps = snapshot.bitrateMbps
        adaptiveActive = snapshot.adaptiveActive
        adaptiveMode = snapshot.adaptiveMode
    }

    private func startLocalPowerPolling() {
        statsTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self else { continue }
                let sampleTime = CACurrentMediaTime()
                let localStats = self.localPowerTelemetry.sample(at: sampleTime)
                let smoothedPower = self.powerUsageMeter.sample(
                    watts: localStats.appPowerWatts, at: sampleTime)
                self.laptopStats = LaptopStats(hasBattery: localStats.hasBattery,
                                                batteryPercent: localStats.batteryPercent,
                                                batteryState: localStats.batteryState,
                                                timeRemainingMinutes: localStats.timeRemainingMinutes,
                                                appPowerWatts: smoothedPower)
                self.powerUsageHigh = self.powerUsageMeter.isHighPower
            }
        }
    }

    #if DEBUG
    static func preview(title: String, phase: Phase) -> StreamController {
        let host = HostRecord(id: "uid", name: "PC", address: "127.0.0.1", isPaired: true)
        let controller = StreamController(host: host, entry: AppLibraryEntry(appId: "1", title: title),
                                          settings: .defaults, capabilities: .unrestricted,
                                          inputPreferences: .defaults)
        controller.machine = ConnectionStateMachine(previewPhase: phase)
        return controller
    }
    #endif

    static func startFailureMessage(_ error: Error) -> String {
        guard case let LiveStreamSessionFailure.start(detail) = error, !detail.isEmpty else {
            return message(for: error)
        }
        if detail.localizedCaseInsensitiveContains("timed out") {
            return "The host stopped responding while starting the stream. "
                + "Check that it is online and try again."
        }
        return detail
    }

    static func message(for error: Error) -> String {
        if error is PairingError { return PairingError.userMessage(for: error) }
        return "Couldn't start the stream: \(error.localizedDescription)"
    }
}
