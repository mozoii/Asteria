import Foundation
import AudioEngine
import Discovery
import GameStreamProtocol
import InputEngine
import AsteriaModel
import Pairing
import VideoEngine

/// Owns Host negotiation and stream resources. Drains frames to DecoderRenderer or nil.
public actor LiveStreamRunner: SessionRunner {
    private let host: HostClient
    private let appId: String
    private let config: StreamConfiguration
    /// Skip /resume even when the app is already running (used to quit+launch after a stalled resume).
    private let forceLaunch: Bool
    private let rikey: [UInt8]
    private let handshakeTimeoutSeconds: UInt64
    private let videoRenderer: DecoderRenderer?
    /// Render seam; nil receives Opus only.
    private let audioRenderer: AudioRenderer?
    /// Pointer capture seam; nil for headless.
    private let inputSurface: StreamSurface?
    /// Forward Windows/Meta to host.
    private let captureSystemKeys: Bool
    private let inputPreferences: InputPreferences
    /// Local hotkey actions for the app shell.
    private let commandSink: (@Sendable (StreamAction) -> Void)?
    private var commandForwardTask: Task<Void, Never>?
    /// Overlay-menu navigation for the app shell.
    private let menuNavSink: (@Sendable (MenuNav) -> Void)?
    private var menuNavForwardTask: Task<Void, Never>?
    /// Host HDR-mode changes for the video path (re-tag the present layer live).
    private let hdrModeSink: (@Sendable (Bool) -> Void)?
    /// Host termination (IDX_TERMINATION code, or a control-peer drop): routes to session.stop(error:).
    private var terminationSink: (@Sendable (UInt32) -> Void)? = nil
    private var terminationForwardTask: Task<Void, Never>?
    private var controlDisconnectTask: Task<Void, Never>?
    /// Sentinel code for a control-peer drop (no host termination message) → mapped non-graceful.
    static let controlDisconnectSentinel: UInt32 = 0xFFFF_FFFF

    /// Set after the owning `Session` exists (runner is built before it): routes host termination
    /// codes (0 = graceful, else — including a control-peer drop — abnormal) to session stop.
    public func setTerminationSink(_ sink: @Sendable @escaping (UInt32) -> Void) {
        self.terminationSink = sink
    }
    /// RFI vs full IDR — decided at handshake.
    public private(set) var referenceInvalidationEnabled = false

    public private(set) var rtspHost: String?
    public private(set) var session: RTSPSessionResult?
    public private(set) var lastSDP: String?
    private var rtspPort: UInt16?
    private var control: ControlStream?
    private var input: InputEngine?
    private var inputRouterTask: Task<Void, Never>?
    private var video: RTPStreamReceiver<AssembledFrame>?
    private var videoAssembler: VideoFrameAssembler?
    /// Last reassembly-loss snapshot, captured at video teardown for post-run telemetry.
    private var videoFrameLoss = VideoFrameAssembler.LossStats()
    private var audio: RTPStreamReceiver<AudioOpusPacket>?
    private var audioPump: AudioDecodePump?
    public private(set) var videoStats = RTPStreamReceiver<AssembledFrame>.Stats()
    public private(set) var audioStats = RTPStreamReceiver<AudioOpusPacket>.Stats()

    /// Audio decode/recovery tracking; nonisolated for live reporting.
    public nonisolated let audioStatsTracker = AudioStatsTracker()

    /// Video decode/recovery tracking; nonisolated for live reporting.
    public nonisolated let statsTracker = VideoStatsTracker()

    public nonisolated var videoFrameStats: VideoStats { statsTracker.snapshot() }

    private var pump: DecodePump?

    enum ConnectionPath: String {
        case control
        case video
        case audio
    }

    enum ConnectionSetupError: Error, CustomStringConvertible {
        case badSessionURL(String)
        case sessionNotPrepared
        case sessionNotNegotiated(ConnectionPath)
        case missingPort(ConnectionPath)
        case invalidPort(ConnectionPath, Int)
        case inputRequiresControl
        case handshakeTimedOut
        public var description: String {
            switch self {
            case .badSessionURL(let u): return "could not parse RTSP session URL: \(u)"
            case .sessionNotPrepared: return "stream session was not prepared before negotiation"
            case .sessionNotNegotiated(let path):
                return "cannot open \(path.rawValue) path before Host session negotiation"
            case .missingPort(let path): return "Host did not provide a \(path.rawValue) port"
            case let .invalidPort(path, port):
                return "Host provided invalid \(path.rawValue) port \(port); expected 0...65535"
            case .inputRequiresControl:
                return "cannot start input because the control path is not open"
            case .handshakeTimedOut: return "RTSP handshake timed out"
            }
        }
    }

    public init(transport: GameStreamTransport, uniqueId: String, appId: String,
                config: StreamConfiguration, rikey: [UInt8], handshakeTimeoutSeconds: UInt64 = 20,
                forceLaunch: Bool = false,
                videoRenderer: DecoderRenderer? = nil, audioRenderer: AudioRenderer? = nil,
                inputSurface: StreamSurface? = nil, captureSystemKeys: Bool = false,
                inputPreferences: InputPreferences = .defaults,
                commandSink: (@Sendable (StreamAction) -> Void)? = nil,
                menuNavSink: (@Sendable (MenuNav) -> Void)? = nil,
                hdrModeSink: (@Sendable (Bool) -> Void)? = nil) {
        self.host = HostClient(transport: transport, uniqueId: uniqueId)
        self.appId = appId
        self.config = config
        self.forceLaunch = forceLaunch
        self.rikey = rikey
        self.handshakeTimeoutSeconds = handshakeTimeoutSeconds
        self.videoRenderer = videoRenderer
        self.audioRenderer = audioRenderer
        self.inputSurface = inputSurface
        self.captureSystemKeys = captureSystemKeys
        self.inputPreferences = inputPreferences
        self.commandSink = commandSink
        self.menuNavSink = menuNavSink
        self.hdrModeSink = hdrModeSink
    }

    public func prepareSession() async throws {
        let launch = try await launchOrResume()
        guard let url = URL(string: launch.rtspSessionURL), let host = url.host else {
            throw ConnectionSetupError.badSessionURL(launch.rtspSessionURL)
        }
        rtspHost = host
        rtspPort = UInt16(url.port ?? 48010)
    }

    public func negotiateSession() async throws {
        try await runHandshake()
    }

    public func openMediaPaths() async throws {
        try await startControl()
        try await startVideo()
        try await startAudio()
        try startInput()
    }

    public func closeSession() async {
        await stopInput()
        await stopAudio()
        await stopVideo()
        await control?.disconnect()
        control = nil
        rtspPort = nil
    }

    private func runHandshake() async throws {
        guard let host = rtspHost, let port = rtspPort else {
            throw ConnectionSetupError.sessionNotPrepared
        }

        let rtsp = RTSPTCPTransport(host: host, port: port)
        let handshake = RTSPHandshake(transport: rtsp, host: host, port: port)
        do {
            let result = try await withThrowingTaskGroup(of: RTSPSessionResult.self) { group in
                group.addTask { try await handshake.perform(config: self.config) }
                group.addTask {
                    try await Task.sleep(nanoseconds: self.handshakeTimeoutSeconds * 1_000_000_000)
                    throw ConnectionSetupError.handshakeTimedOut
                }
                defer { group.cancelAll() }
                return try await group.next()!
            }
            session = result
            // Decide loss-recovery strategy now that the host's capabilities are known: RFI if the host
            // advertises it and the negotiated codec supports VT reference-frame invalidation, else IDR.
            referenceInvalidationEnabled = Self.referenceInvalidationEnabled(
                serverSDP: result.serverSDP, videoFormat: config.videoFormat)
        } catch {
            lastSDP = await handshake.lastServerSDP
            throw error
        }
    }

    private func stopInput() async {
        inputRouterTask?.cancel()
        inputRouterTask = nil
        commandForwardTask?.cancel()
        commandForwardTask = nil
        menuNavForwardTask?.cancel()
        menuNavForwardTask = nil
        terminationForwardTask?.cancel()
        terminationForwardTask = nil
        controlDisconnectTask?.cancel()
        controlDisconnectTask = nil
        await input?.stop()
        input = nil
    }

    private func stopAudio() async {
        if let audio { audioStats = await audio.stop() }
        audio = nil
        audioPump = nil
        if let audioRenderer { await audioRenderer.stop() }
    }

    private func stopVideo() async {
        if let videoAssembler { videoFrameLoss = videoAssembler.lossStats() }
        videoAssembler = nil
        if let video { videoStats = await video.stop() }
        video = nil
        if let pump { await pump.finish() }
        pump = nil
        if let videoRenderer { await videoRenderer.stop() }
    }

    /// Set when this connection /resume'd a running app (vs a fresh /launch); drives the no-video watchdog.
    public private(set) var didResume = false

    /// Resume only the same already-running app; a different running app is cancelled first, idle hosts launch.
    private func launchOrResume() async throws -> LaunchSession {
        let running = await runningGameId()
        if !forceLaunch, let running, String(running) == appId {
            didResume = true
            return try await host.resume(appId: appId, config: config,
                                         localAudioPlayMode: config.playAudioOnHost)
        }
        if running != nil {
            _ = try? await host.cancel()
            await waitForHostIdle()
        }
        return try await host.launch(appId: appId, config: config,
                                     localAudioPlayMode: config.playAudioOnHost)
    }

    /// Host's currently-running app id, or nil when idle (currentGame == 0) or serverinfo unavailable.
    private func runningGameId() async -> Int? {
        guard let data = try? await host.serverInfo(),
              let info = try? ServerInfoParser.parse(data),
              info.currentGame != 0 else { return nil }
        return info.currentGame
    }

    private func hostHasRunningSession() async -> Bool {
        await runningGameId() != nil
    }

    /// Poll until host reports no running game (so /launch won't be rejected).
    private func waitForHostIdle(maxAttempts: Int = 10) async {
        for _ in 0..<maxAttempts {
            if !(await hostHasRunningSession()) { return }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
    }

    /// RFI only when advertised in SDP AND codec supports VT reference-frame invalidation.
    static func referenceInvalidationEnabled(serverSDP: String, videoFormat: VideoFormat) -> Bool {
        let advertised = SessionDescription(parsing: serverSDP)?.advertisesReferenceFrameInvalidation ?? false
        return advertised && DecoderCapabilities.supportsReferenceFrameInvalidation(for: videoFormat)
    }

    private func startControl() async throws {
        FileHandle.standardError.write(Data(
            "net QoS: video/audio=\(NetworkQoS.streamServiceClass), control=\(NetworkQoS.controlServiceClass), p2p=\(NetworkQoS.includePeerToPeer ? "on" : "off")\n".utf8))
        let endpoint = try endpoint(for: .control)
        let control = ControlStream(host: endpoint.host, port: endpoint.port,
                                    connectData: endpoint.session.controlConnectData, rikey: rikey)
        try await control.connect()
        await control.startServiceLoop()
        self.control = control
    }

    private func startVideo() async throws {
        let endpoint = try endpoint(for: .video)

        let assembler = VideoFrameAssembler(packetSize: config.packetSize)
        let video = RTPStreamReceiver.video(assembler: assembler, host: endpoint.host,
                                            port: endpoint.port,
                                            pingPayload: endpoint.session.videoPingPayload)
        self.videoAssembler = assembler

        if let renderer = videoRenderer {
            let pump = DecodePump(renderer: renderer,
                                  sink: ControlRecoverySink(control: self.control),
                                  stats: self.statsTracker,
                                  referenceInvalidationSupported: referenceInvalidationEnabled)
            await pump.start()
            self.pump = pump
            await video.start(onOutput: { frame in pump.yield(frame) })
        } else {
            await video.start()
        }
        self.video = video
    }

    /// Adapts recovery decisions to control stream (best-effort).
    private struct ControlRecoverySink: RecoverySink {
        let control: ControlStream?
        func requestRecovery(_ request: RecoveryController.Request) async {
            try? await control?.send(LiveStreamRunner.controlMessage(for: request),
                                     channel: ControlMessage.channelUrgent)
        }
    }

    static func controlMessage(for request: RecoveryController.Request) -> ControlMessage.Message {
        switch request {
        case .idr:
            return ControlMessage.requestIdr
        case .invalidateReferenceFrames(let first, let last):
            return ControlMessage.invalidateReferenceFrames(first: first, last: last)
        }
    }

    private func startAudio() async throws {
        let endpoint = try endpoint(for: .audio)
        let audio = try RTPStreamReceiver.audio(host: endpoint.host, port: endpoint.port,
                                                pingPayload: endpoint.session.audioPingPayload)

        // Audio stays on the host's own output: keep the receiver running so its ping task feeds the
        // host's initial-ping gate, but decode and render nothing.
        if config.playAudioOnHost {
            await audio.start(onOutput: nil)
            self.audio = audio
            return
        }

        if let renderer = audioRenderer,
           let pump = await makeAudioPump(renderer: renderer, sdp: endpoint.session.serverSDP) {
            self.audioPump = pump
            await audio.start(onOutput: { pump.ingest($0) })
        } else {
            if audioRenderer != nil {
                FileHandle.standardError.write(Data("audio: receive-only (decode/render setup failed)\n".utf8))
            }
            await audio.start()
        }
        self.audio = audio
    }

    /// Build decode pump and start renderer; nil on failure (audio degrades gracefully).
    private func makeAudioPump(renderer: AudioRenderer, sdp: String) async -> AudioDecodePump? {
        guard let opus = OpusMultistreamConfig.derive(audio: config.audio, serverSDP: sdp),
              let remap = ChannelRemap(channelCount: opus.channelCount),
              let decoder = try? OpusAudioDecoder(
                sampleRate: opus.sampleRate, channelCount: opus.channelCount, streams: opus.streams,
                coupledStreams: opus.coupledStreams, mapping: opus.mapping,
                samplesPerFrame: opus.samplesPerFrame) else { return nil }
        do {
            try await renderer.start(format: AudioRenderFormat(
                sampleRate: Int(opus.sampleRate), channelCount: opus.channelCount, layoutTag: remap.layoutTag))
        } catch {
            FileHandle.standardError.write(Data("audio: renderer start failed, degrading to receive-only: \(error)\n".utf8))
            return nil
        }
        FileHandle.standardError.write(Data("audio: decoding \(opus.channelCount)ch via \(type(of: renderer))\n".utf8))
        return AudioDecodePump(decoder: decoder, remap: remap, renderer: renderer, stats: audioStatsTracker)
    }

    /// Build InputEngine over control stream (shared, no separate socket).
    private func startInput() throws {
        guard let control else { throw ConnectionSetupError.inputRequiresControl }
        let engine = InputEngine(transport: control,
                                 keybindings: inputPreferences.keybindings,
                                 mouseMode: inputPreferences.mouseMode,
                                 swapFaceButtons: inputPreferences.swapFaceButtons,
                                 swapMouseButtons: inputPreferences.swapMouseButtons,
                                 swapWinAltKeys: inputPreferences.swapWinAltKeys,
                                 playStationEmulation: inputPreferences.playStationEmulation,
                                 playStationLEDColor: inputPreferences.playStationLEDColor,
                                 systemKeyCaptureActive: captureSystemKeys,
                                 streamWidth: config.width, streamHeight: config.height,
                                 surface: inputSurface)
        engine.start()
        self.input = engine
        let messages = control.hostMessages
        let hdrModeSink = self.hdrModeSink
        inputRouterTask = Task {
            for await message in messages {
                if case let .setHdrMode(enabled) = message { hdrModeSink?(enabled) }
                engine.handle(message)
            }
        }
        if let commandSink {
            let commands = engine.commands
            commandForwardTask = Task { for await action in commands { commandSink(action) } }
        }
        if let menuNavSink {
            let menuEvents = engine.menuEvents
            menuNavForwardTask = Task { for await nav in menuEvents { menuNavSink(nav) } }
        }
        if let terminationSink {
            let terminations = engine.terminations
            terminationForwardTask = Task { for await code in terminations { terminationSink(code) } }
            let disconnects = control.disconnects
            controlDisconnectTask = Task {
                // A control-peer drop means the host/network is gone with no termination message:
                // surface it through the same sink as a non-graceful (sentinel) termination.
                for await _ in disconnects { terminationSink(Self.controlDisconnectSentinel) }
            }
        }
    }

    private func endpoint(
        for path: ConnectionPath
    ) throws -> (host: String, port: UInt16, session: RTSPSessionResult) {
        guard let host = rtspHost, let session else {
            throw ConnectionSetupError.sessionNotNegotiated(path)
        }
        let rawPort: Int?
        switch path {
        case .control: rawPort = session.controlPort
        case .video: rawPort = session.videoPort
        case .audio: rawPort = session.audioPort
        }
        guard let rawPort else { throw ConnectionSetupError.missingPort(path) }
        guard let port = UInt16(exactly: rawPort) else {
            throw ConnectionSetupError.invalidPort(path, rawPort)
        }
        return (host, port, session)
    }

    /// Drive local input capture (no-op if input not started).
    public func setInputCapture(_ active: Bool) { input?.setCaptureActive(active) }

    /// NSEvent keyboard/mouse sink (nil until input starts).
    public var localInput: LocalInputSink? { input }

    /// Toggle pointer mode (no-op if input not started).
    public func toggleMouseMode() { input?.toggleMouseMode() }

    /// Toggle overlay-menu mode (no-op if input not started).
    public func setMenuOpen(_ open: Bool) { input?.setMenuOpen(open) }

    #if DEBUG
    /// Fire the haptics test sweep at the first connected controller.
    public func fireTestRumble() { input?.fireTestRumble() }
    #endif

    /// Audio stats snapshot: decode counters + renderer ring metrics.
    private var audioStatsSnapshot: AudioStats {
        var stats = audioStatsTracker.snapshot()
        if let render = audioRenderer?.renderStats() { stats.render = render }
        return stats
    }

    /// Live telemetry sample from receivers and handshake facts.
    public var telemetry: StreamTelemetry {
        get async {
            let frameLoss = videoAssembler?.lossStats() ?? videoFrameLoss
            return StreamTelemetry(
                videoTransport: await video?.snapshot() ?? videoStats,
                audioTransport: await audio?.snapshot() ?? audioStats,
                decode: statsTracker.snapshot(),
                videoFrameLoss: frameLoss,
                audio: audioStatsSnapshot,
                input: input?.inputStats ?? InputStats(),
                control: input?.inboundCounts ?? InboundControlCounts(),
                controlRoundTripMillis: await control?.roundTripTimeMillis ?? 0,
                referenceInvalidationEnabled: referenceInvalidationEnabled,
                rtspSession: session,
                lastSDP: lastSDP)
        }
    }
}
