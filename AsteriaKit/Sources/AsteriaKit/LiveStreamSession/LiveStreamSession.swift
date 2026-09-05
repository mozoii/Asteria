import Foundation
import AsteriaModel
import AudioEngine
import Discovery
import GameStreamProtocol
import InputEngine
import LiveSession
import Pairing
import VideoEngine

public enum LiveStreamSessionFailure: Error, LocalizedError, Equatable, Sendable {
    case pairedAccess(PairedHostAccessError)
    case connection(detail: String)
    case start(detail: String)

    public var errorDescription: String? {
        switch self {
        case let .pairedAccess(error): error.localizedDescription
        case let .connection(detail): "Couldn't prepare the live stream: \(detail)"
        case let .start(detail): "Couldn't start the live stream: \(detail)"
        }
    }
}

public struct LiveClipboardSnapshot: Equatable, Sendable {
    public let changeCount: Int
    public let text: String?

    public init(changeCount: Int, text: String?) {
        self.changeCount = changeCount
        self.text = text
    }
}

public struct LivePresentationMetrics: Equatable, Sendable {
    public var deliveredFrames: Int
    public var presentedFrames: Int
    public var meanDecodeMillis: Double

    public init(
        deliveredFrames: Int = 0,
        presentedFrames: Int = 0,
        meanDecodeMillis: Double = 0
    ) {
        self.deliveredFrames = deliveredFrames
        self.presentedFrames = presentedFrames
        self.meanDecodeMillis = meanDecodeMillis
    }

    public static let zero = LivePresentationMetrics()
}

public struct LiveRuntimeSnapshot: Equatable, Sendable {
    public let telemetry: StreamTelemetry
    public let presentation: LivePresentationMetrics
    public let bitrateMbps: Double
    public let adaptiveActive: Bool
    public let adaptiveMode: AdaptiveMode
    /// Monotonic uptime (nanos) at publish time, so consumers can normalize rates over the actual interval.
    public let timestampNanos: UInt64

    public init(
        telemetry: StreamTelemetry,
        presentation: LivePresentationMetrics,
        bitrateMbps: Double,
        adaptiveActive: Bool,
        adaptiveMode: AdaptiveMode,
        timestampNanos: UInt64 = 0
    ) {
        self.telemetry = telemetry
        self.presentation = presentation
        self.bitrateMbps = bitrateMbps
        self.adaptiveActive = adaptiveActive
        self.adaptiveMode = adaptiveMode
        self.timestampNanos = timestampNanos
    }
}

public actor LiveStreamSession {
    public enum Intent: Sendable {
        /// Machine events in their own shape — the shell applies them without re-mapping.
        case lifecycle(ConnectionStateMachine.Event)
        case command(StreamAction)
        case menuNavigation(MenuNav)
        case hdrModeChanged(Bool)
        case runtimeSnapshot(LiveRuntimeSnapshot)
        case notification(String)
        case adaptiveModeChanged(AdaptiveMode)
    }

    private enum AdaptiveDriver { case none, local, foundation }

    private let session: StreamSession
    private let client: HostClient
    private let settings: StreamSettings
    private let initialBitrateKbps: Int
    private let presentationMetrics: @Sendable () async -> LivePresentationMetrics
    private let clipboardSnapshot: (@Sendable () async -> LiveClipboardSnapshot)?
    private let intentContinuation: AsyncStream<Intent>.Continuation
    private var forwardingTasks: [Task<Void, Never>] = []
    private var runtimeTask: Task<Void, Never>?
    private var resumeWatchdogTask: Task<Void, Never>?
    private var clipboardTask: Task<Void, Never>?
    private var feedbackTask: Task<Void, Never>?
    private var bitrateMeter = RateMeter()
    private var livenessWatchdog = StreamLivenessWatchdog()
    private var adaptiveController: AdaptiveBitrateController?
    private var adaptiveDriver = AdaptiveDriver.none
    private var adaptiveMode: AdaptiveMode
    private var adaptiveActive = false

    public nonisolated let videoFormat: VideoFormat
    public nonisolated let intents: AsyncStream<Intent>

    private init(
        session: StreamSession,
        client: HostClient,
        settings: StreamSettings,
        initialBitrateKbps: Int,
        presentationMetrics: @escaping @Sendable () async -> LivePresentationMetrics,
        clipboardSnapshot: (@Sendable () async -> LiveClipboardSnapshot)?
    ) {
        self.session = session
        self.client = client
        self.settings = settings
        self.initialBitrateKbps = initialBitrateKbps
        self.presentationMetrics = presentationMetrics
        self.clipboardSnapshot = clipboardSnapshot
        self.adaptiveMode = settings.adaptiveMode
        self.videoFormat = session.videoFormat
        let (intents, continuation) = AsyncStream<Intent>.makeStream()
        self.intents = intents
        self.intentContinuation = continuation
    }

    public static func connect(
        profile: HostRecord,
        identities: ClientIdentityVault,
        settings: StreamSettings,
        plan: StreamConfigBuilder.Plan,
        videoSink: any VideoSink,
        audioRenderer: (any AudioRenderer)? = nil,
        inputSurface: (any StreamSurface)? = nil,
        captureSystemKeys: Bool = false,
        inputPreferences: InputPreferences = .defaults,
        forceLaunch: Bool = false,
        presentationMetrics: @escaping @Sendable () async -> LivePresentationMetrics = { .zero },
        clipboardSnapshot: (@Sendable () async -> LiveClipboardSnapshot)? = nil
    ) async throws -> LiveStreamSession {
        let access: PairedHostAccess
        do {
            access = try PairedHostAccess(profile: profile, identities: identities)
        } catch let error as PairedHostAccessError {
            throw LiveStreamSessionFailure.pairedAccess(error)
        } catch {
            throw LiveStreamSessionFailure.connection(detail: error.localizedDescription)
        }

        do {
            let stream = try await makeStreamSession(
                profile: profile,
                access: access,
                plan: plan,
                videoSink: videoSink,
                audioRenderer: audioRenderer,
                inputSurface: inputSurface,
                captureSystemKeys: captureSystemKeys,
                inputPreferences: inputPreferences,
                forceLaunch: forceLaunch
            )
            let liveSession = LiveStreamSession(
                session: stream,
                client: access.hostClient(),
                settings: settings,
                initialBitrateKbps: plan.configuration.bitrateKbps,
                presentationMetrics: presentationMetrics,
                clipboardSnapshot: clipboardSnapshot
            )
            await liveSession.startForwardingIntents()
            return liveSession
        } catch {
            throw LiveStreamSessionFailure.connection(detail: error.localizedDescription)
        }
    }

    public func start() async throws {
        switch await session.start() {
        case .success:
            await startClipboardIfEnabled()
            await startAdaptiveIfEnabled()
            startRuntimeSnapshots()
            if await session.didResume { startResumeWatchdog() }
        case let .failure(error):
            throw LiveStreamSessionFailure.start(detail: error.message)
        }
    }

    /// A resumed encoder that never re-armed sends zero video bytes; if none arrive within the
    /// grace window, surface the quit+relaunch prompt rather than stranding the user on black.
    private func startResumeWatchdog() {
        resumeWatchdogTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled, let self else { return }
            if await self.session.videoBytesReceived == 0 {
                self.intentContinuation.yield(.lifecycle(.resumeStalled))
            }
        }
    }

    public func stop(error: TerminationError = .graceful) async {
        runtimeTask?.cancel()
        resumeWatchdogTask?.cancel()
        clipboardTask?.cancel()
        feedbackTask?.cancel()
        await stopAdaptive()
        forwardingTasks.forEach { $0.cancel() }
        forwardingTasks.removeAll()
        // Bound the stop: a wedged subsystem can't hang the caller.
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { await self.session.stop(error: error); return true }
            group.addTask {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                return false
            }
            _ = await group.next()
            group.cancelAll()
        }
        intentContinuation.finish()
    }

    public func setAdaptiveMode(_ mode: AdaptiveMode) async -> Bool {
        guard mode != adaptiveMode else { return true }
        if adaptiveDriver == .foundation {
            return await setFoundationAdaptiveMode(mode)
        }
        adaptiveMode = mode
        if adaptiveDriver == .local, var controller = adaptiveController {
            let target = controller.setMode(mode)
            adaptiveController = controller
            if let target { _ = try? await client.setBitrate(kbps: target) }
        }
        intentContinuation.yield(.adaptiveModeChanged(mode))
        return true
    }

    public func setInputCapture(_ active: Bool) async {
        await session.setInputCapture(active)
    }

    public var localInput: LocalInputSink? {
        get async { await session.localInput }
    }

    public func toggleMouseMode() async { await session.toggleMouseMode() }
    public func setMenuOpen(_ open: Bool) async { await session.setMenuOpen(open) }

    #if DEBUG
    public func fireTestRumble() async { await session.fireTestRumble() }
    #endif

    public func cancel() async throws -> Bool { try await client.cancel() }
    public var didResume: Bool { get async { await session.didResume } }
    public var telemetry: StreamTelemetry { get async { await session.telemetry } }

    private static func makeStreamSession(
        profile: HostRecord,
        access: PairedHostAccess,
        plan: StreamConfigBuilder.Plan,
        videoSink: any VideoSink,
        audioRenderer: (any AudioRenderer)?,
        inputSurface: (any StreamSurface)?,
        captureSystemKeys: Bool,
        inputPreferences: InputPreferences,
        forceLaunch: Bool
    ) async throws -> StreamSession {
        try await StreamSession.connect(
            host: profile.address,
            transport: access.transport,
            uniqueId: access.uniqueID,
            videoSink: videoSink,
            audioRenderer: audioRenderer,
            inputSurface: inputSurface,
            captureSystemKeys: captureSystemKeys,
            inputPreferences: inputPreferences,
            preferTenBit: plan.preferTenBit,
            codec: plan.codec,
            forceLaunch: forceLaunch,
            config: plan.configuration
        )
    }

    private func startRuntimeSnapshots() {
        runtimeTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                await self.publishRuntimeSnapshot()
            }
        }
    }

    private func publishRuntimeSnapshot() async {
        let telemetry = await session.telemetry
        let presentation = await presentationMetrics()
        let bytes = telemetry.videoTransport.bytes + telemetry.audioTransport.bytes
        let bitrate = bitrateMeter.sample(
            totalBytes: bytes,
            at: Date().timeIntervalSinceReferenceDate
        )
        driveLocalAdaptive(lossPercent: telemetry.decode.lossRate * 100)
        // One clock sample shared by the liveness check and the snapshot timestamp.
        let now = DispatchTime.now().uptimeNanoseconds
        // Safety net for a host that dies without a termination message (crash, network drop):
        // a flat video byte counter or a stalled present path tears the session down.
        if let reason = livenessWatchdog.observe(
            videoBytes: telemetry.videoTransport.bytes,
            deliveredFrames: presentation.deliveredFrames,
            now: now
        ) {
            Task { await session.stop(error: reason) }
        }
        intentContinuation.yield(.runtimeSnapshot(LiveRuntimeSnapshot(
            telemetry: telemetry,
            presentation: presentation,
            bitrateMbps: bitrate,
            adaptiveActive: adaptiveActive,
            adaptiveMode: adaptiveMode,
            timestampNanos: now
        )))
    }

    private func startClipboardIfEnabled() async {
        guard settings.syncClipboard, let clipboardSnapshot else { return }
        guard let data = try? await client.serverInfo(),
              let info = try? ServerInfoParser.parse(data),
              info.isApolloFamily else { return }
        clipboardTask = Task { [weak self] in
            var model = ClipboardSyncModel()
            while !Task.isCancelled {
                guard let self else { return }
                let snapshot = await clipboardSnapshot()
                if let text = model.textToSync(
                    changeCount: snapshot.changeCount,
                    text: snapshot.text
                ) {
                    try? await self.client.setClipboard(text)
                }
                try? await Task.sleep(for: .milliseconds(700))
            }
        }
    }

    private func startAdaptiveIfEnabled() async {
        guard settings.bitrate.isAdaptive, initialBitrateKbps > 0 else { return }
        do {
            let capabilities = try await client.abrCapabilities()
            guard capabilities.isCompatible else { startLocalAdaptive(); return }
            let response = try await client.configureAbr(abrConfiguration(for: adaptiveMode))
            guard response.success, response.enabled else { startLocalAdaptive(); return }
            adaptiveDriver = .foundation
            adaptiveActive = true
            startFoundationFeedback()
            notify("Adaptive bitrate is active in \(adaptiveMode.shortName) mode.")
        } catch {
            await handleFoundationEnableError(error)
        }
    }

    private func handleFoundationEnableError(_ error: Error) async {
        if case .httpStatus = error as? PairingError { startLocalAdaptive(); return }
        if await disableFoundationAbr(timeoutSeconds: 1) {
            startLocalAdaptive()
        } else {
            notify("Adaptive bitrate couldn't be started safely. Using Auto bitrate.")
        }
    }

    private func startLocalAdaptive() {
        adaptiveController = AdaptiveBitrateController(
            initialKbps: initialBitrateKbps,
            mode: adaptiveMode
        )
        adaptiveDriver = .local
        adaptiveActive = true
        notify("Adaptive bitrate is active in \(adaptiveMode.shortName) mode.")
    }

    private func driveLocalAdaptive(lossPercent: Double) {
        guard adaptiveDriver == .local, var controller = adaptiveController else { return }
        guard let target = controller.tick(lossPercent: lossPercent) else {
            adaptiveController = controller
            return
        }
        adaptiveController = controller
        Task { [weak self] in
            guard let self else { return }
            let applied = (try? await self.client.setBitrate(kbps: target)) ?? 0
            guard applied <= 0 else { return }
            await self.disableLocalAdaptiveAfterRejection()
        }
    }

    private func disableLocalAdaptiveAfterRejection() {
        adaptiveController = nil
        adaptiveDriver = .none
        adaptiveActive = false
        notify("Adaptive bitrate isn't supported by this host. Using Auto bitrate for this stream.")
    }

    private func setFoundationAdaptiveMode(_ mode: AdaptiveMode) async -> Bool {
        do {
            let response = try await client.configureAbr(abrConfiguration(for: mode))
            guard response.success, response.enabled else {
                notify("Couldn't switch adaptive bitrate to \(mode.shortName) mode.")
                return false
            }
            adaptiveMode = mode
            intentContinuation.yield(.adaptiveModeChanged(mode))
            return true
        } catch {
            notify("Couldn't switch adaptive bitrate to \(mode.shortName) mode.")
            return false
        }
    }

    private func abrConfiguration(for mode: AdaptiveMode) -> FoundationABRConfiguration {
        let controller = AdaptiveBitrateController(initialKbps: initialBitrateKbps, mode: mode)
        return FoundationABRConfiguration(
            enabled: true,
            mode: mode == .preferQuality ? .quality : .lowLatency,
            minBitrateKbps: controller.floorKbps,
            maxBitrateKbps: initialBitrateKbps
        )
    }

    private func startFoundationFeedback() {
        feedbackTask = Task { [weak self] in
            guard let self else { return }
            var sampler = FoundationABRSampler()
            var delaySeconds = 1
            var failures = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(delaySeconds))
                guard let snapshot = await self.abrSnapshot(),
                      let sample = sampler.sample(snapshot) else { continue }
                do {
                    _ = try await self.client.sendAbrFeedback(Self.feedback(from: sample))
                    failures = 0
                    delaySeconds = 1
                } catch {
                    failures += 1
                    delaySeconds = min(delaySeconds * 2, 8)
                    if failures == 3 { await self.notifyFeedbackInterrupted() }
                }
            }
        }
    }

    private func abrSnapshot() async -> FoundationABRSnapshot? {
        let telemetry = await session.telemetry
        let presentation = await presentationMetrics()
        return FoundationABRSnapshot(
            time: Date().timeIntervalSinceReferenceDate,
            frames: FoundationABRFrameCounters(
                decoded: presentation.deliveredFrames,
                delivered: telemetry.decode.delivered,
                networkLost: telemetry.decode.networkLost,
                dropped: telemetry.decode.needsIdr + telemetry.decode.dropped
            ),
            videoBytes: telemetry.videoTransport.bytes,
            rttMillis: Int(telemetry.controlRoundTripMillis)
        )
    }

    private static func feedback(from sample: FoundationABRSample) -> FoundationABRFeedback {
        FoundationABRFeedback(
            packetLossPercent: sample.packetLossPercent,
            rttMillis: sample.rttMillis,
            decodeFps: sample.decodeFps,
            droppedFrames: sample.droppedFrames,
            currentBitrateKbps: sample.currentBitrateKbps
        )
    }

    private func notifyFeedbackInterrupted() {
        notify("Adaptive bitrate feedback was interrupted. Retrying.")
    }

    private func stopAdaptive() async {
        feedbackTask?.cancel()
        if adaptiveDriver == .foundation { _ = await disableFoundationAbr(timeoutSeconds: 1) }
        adaptiveController = nil
        adaptiveDriver = .none
        adaptiveActive = false
    }

    private func disableFoundationAbr(timeoutSeconds: Int) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { (try? await self.client.disableAbr().success) == true }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeoutSeconds))
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }

    private func notify(_ message: String) {
        intentContinuation.yield(.notification(message))
    }

    private func startForwardingIntents() {
        let continuation = intentContinuation
        let stream = session
        forwardingTasks = [
            Task {
                for await event in stream.events {
                    switch event {
                    case .connectionStarted:
                        continuation.yield(.lifecycle(.streamLive))
                    case let .connectionTerminated(reason):
                        continuation.yield(.lifecycle(.terminated(reason: reason)))
                    default: break   // failures surface through start()'s thrown error
                    }
                }
            },
            Task {
                for await command in stream.commands { continuation.yield(.command(command)) }
            },
            Task {
                for await navigation in stream.menuEvents {
                    continuation.yield(.menuNavigation(navigation))
                }
            },
            Task {
                for await enabled in stream.hdrModeChanges {
                    continuation.yield(.hdrModeChanged(enabled))
                }
            },
        ]
    }
}
