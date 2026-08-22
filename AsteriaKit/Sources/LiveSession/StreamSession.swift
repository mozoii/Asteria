import Foundation
import AudioEngine
import GameStreamProtocol
import InputEngine
import AsteriaModel
import Pairing
import VideoEngine

/// Builds a decode renderer for the negotiated codec (nil for AV1 or headless).
public protocol VideoSink: Sendable {
    func makeRenderer(for videoFormat: VideoFormat) async -> DecoderRenderer?
}

/// Orchestrates negotiation, configuration assembly, and Session lifecycle.
public actor StreamSession {
    /// Stream parameters (defaults: 1080p60, 20 Mbps, stereo SDR).
    public struct Configuration: Sendable {
        public var appId: String
        public var width: Int
        public var height: Int
        public var fps: Int
        public var bitrateKbps: Int
        public var packetSize: Int
        public var audio: AudioConfiguration
        public var hdr: Bool
        public var hdrDisplay: Bool
        public var playAudioOnHost: Bool

        public init(appId: String = "1639965107", width: Int = 1920, height: Int = 1080, fps: Int = 60,
                    bitrateKbps: Int = 20_000, packetSize: Int = 1392,
                    audio: AudioConfiguration = .stereo, hdr: Bool = false, hdrDisplay: Bool = false,
                    playAudioOnHost: Bool = false) {
            self.appId = appId
            self.width = width
            self.height = height
            self.fps = fps
            self.bitrateKbps = bitrateKbps
            self.packetSize = packetSize
            self.audio = audio
            self.hdr = hdr
            self.hdrDisplay = hdrDisplay
            self.playAudioOnHost = playAudioOnHost
        }

        /// Assemble wire config for negotiated codec and fresh remote-input key.
        func streamConfiguration(videoFormat: VideoFormat,
                                 remoteInput: (key: [UInt8], keyId: Int32)) -> StreamConfiguration {
            StreamConfiguration(width: width, height: height, fps: fps, bitrateKbps: bitrateKbps,
                                packetSize: packetSize, videoFormat: videoFormat, audio: audio, hdr: hdr,
                                playAudioOnHost: playAudioOnHost,
                                remoteInputAesKey: remoteInput.key, remoteInputAesKeyId: remoteInput.keyId)
        }
    }

    private let runner: LiveStreamRunner
    private let session: Session
    private let transport: GameStreamTransport
    private let uniqueId: String
    private let commandContinuation: AsyncStream<StreamAction>.Continuation
    private let menuNavContinuation: AsyncStream<MenuNav>.Continuation
    private let hdrModeContinuation: AsyncStream<Bool>.Continuation

    /// Negotiated codec (Mac caps ∩ host offer).
    public nonisolated let videoFormat: VideoFormat
    /// Session lifecycle event stream; subscribe before `start()`.
    public nonisolated var events: AsyncStream<SessionEvent> { session.events }
    /// Local hotkey actions (controller combos + keyboard chords); ends at `stop()`.
    public nonisolated let commands: AsyncStream<StreamAction>
    /// Overlay-menu navigation while open; ends at `stop()`.
    public nonisolated let menuEvents: AsyncStream<MenuNav>
    /// Host HDR-mode changes (from `setHdrMode`); the app re-tags the present layer. Ends at `stop()`.
    public nonisolated let hdrModeChanges: AsyncStream<Bool>

    private init(runner: LiveStreamRunner, session: Session, transport: GameStreamTransport,
                 uniqueId: String, videoFormat: VideoFormat,
                 commands: AsyncStream<StreamAction>,
                 commandContinuation: AsyncStream<StreamAction>.Continuation,
                 menuEvents: AsyncStream<MenuNav>,
                 menuNavContinuation: AsyncStream<MenuNav>.Continuation,
                 hdrModeChanges: AsyncStream<Bool>,
                 hdrModeContinuation: AsyncStream<Bool>.Continuation) {
        self.runner = runner
        self.session = session
        self.transport = transport
        self.uniqueId = uniqueId
        self.videoFormat = videoFormat
        self.commands = commands
        self.commandContinuation = commandContinuation
        self.menuEvents = menuEvents
        self.menuNavContinuation = menuNavContinuation
        self.hdrModeChanges = hdrModeChanges
        self.hdrModeContinuation = hdrModeContinuation
    }

    /// Negotiate and assemble from prebuilt pinned transport. Does not start — subscribe to events/commands first.
    public static func connect(host: String, transport: GameStreamTransport, uniqueId: String,
                               videoSink: VideoSink, audioRenderer: AudioRenderer? = nil,
                               inputSurface: StreamSurface? = nil, captureSystemKeys: Bool = false,
                               inputPreferences: InputPreferences = .defaults, preferTenBit: Bool = false,
                               codec: CodecPreference = .auto, forceLaunch: Bool = false,
                               config: Configuration = .init()) async throws -> StreamSession {
        let videoFormat = await CapabilityNegotiator.negotiateVideoFormat(
            host: host, codec: codec, hdrDisplay: config.hdrDisplay, preferTenBit: preferTenBit)
        let streamConfig = config.streamConfiguration(videoFormat: videoFormat,
                                                      remoteInput: StreamConfiguration.randomRemoteInput())
        let renderer = await videoSink.makeRenderer(for: videoFormat)
        let (commands, continuation) = AsyncStream<StreamAction>.makeStream()
        let (menuEvents, menuContinuation) = AsyncStream<MenuNav>.makeStream()
        let (hdrModeChanges, hdrContinuation) = AsyncStream<Bool>.makeStream()
        let runner = LiveStreamRunner(transport: transport, uniqueId: uniqueId, appId: config.appId,
                                      config: streamConfig, rikey: streamConfig.remoteInputAesKey,
                                      forceLaunch: forceLaunch,
                                      videoRenderer: renderer, audioRenderer: audioRenderer,
                                      inputSurface: inputSurface, captureSystemKeys: captureSystemKeys,
                                      inputPreferences: inputPreferences,
                                      commandSink: { continuation.yield($0) },
                                      menuNavSink: { menuContinuation.yield($0) },
                                      hdrModeSink: { hdrContinuation.yield($0) })
        let session = Session(runner: runner)
        // Host termination (and control-peer drop) tears the session down instead of freezing on a dead stream.
        await runner.setTerminationSink { code in
            let reason: TerminationError = code == 0 ? .graceful : .unexpectedEarlyTermination
            Task { await session.stop(error: reason) }
        }
        return StreamSession(runner: runner, session: session, transport: transport,
                             uniqueId: uniqueId, videoFormat: videoFormat,
                             commands: commands, commandContinuation: continuation,
                             menuEvents: menuEvents, menuNavContinuation: menuContinuation,
                             hdrModeChanges: hdrModeChanges, hdrModeContinuation: hdrContinuation)
    }

    /// Run the connection lifecycle to `connectionStarted` or failure.
    @discardableResult
    public func start() async -> Result<Void, SessionStartFailure> { await session.start() }

    /// Tear down the session with a termination reason (`.graceful` for a client-initiated stop).
    public func stop(error: TerminationError = .graceful) async {
        await session.stop(error: error)
        commandContinuation.finish()
        menuNavContinuation.finish()
        hdrModeContinuation.finish()
    }

    /// Drive local input capture.
    public func setInputCapture(_ active: Bool) async { await runner.setInputCapture(active) }

    /// NSEvent keyboard/mouse sink, available once streaming starts.
    public var localInput: LocalInputSink? { get async { await runner.localInput } }

    /// Toggle pointer mode (Game/Desktop).
    public func toggleMouseMode() async { await runner.toggleMouseMode() }

    /// Toggle overlay-menu mode.
    public func setMenuOpen(_ open: Bool) async { await runner.setMenuOpen(open) }

    #if DEBUG
    /// Fire the haptics test sweep at the first connected controller.
    public func fireTestRumble() async { await runner.fireTestRumble() }
    #endif

    /// GET /cancel — quit host's running session (call after `stop()`).
    @discardableResult
    public func cancel() async throws -> Bool {
        try await HostClient(transport: transport, uniqueId: uniqueId).cancel()
    }

    /// True when this connection reconnected to a running app via /resume (vs a fresh /launch).
    public var didResume: Bool { get async { await runner.didResume } }

    /// Live telemetry sample (counters + handshake facts).
    public var telemetry: StreamTelemetry { get async { await runner.telemetry } }

    /// Total video bytes received since the session opened — the resume watchdog's stall signal.
    public var videoBytesReceived: Int {
        get async { await runner.telemetry.videoTransport.bytes }
    }
}
