import Foundation
import Synchronization

/// RTP-over-UDP receiver with ordered synchronous assembly on the source callback queue.
public final class RTPStreamReceiver<Output: Sendable>: @unchecked Sendable {
    public struct Stats: Sendable, Equatable {
        public var datagrams = 0
        public var bytes = 0
        public var outputs = 0
        public var recovered = 0
        /// Uptime (nanos) of the last received datagram; nil until the first datagram.
        public var lastActivityNanos: UInt64?
        public init() {}
    }

    private struct State: Sendable {
        var pingTask: Task<Void, Never>?
        var pingSeq: UInt32 = 0
        var running = false
        var stats = Stats()
        var onOutput: (@Sendable (Output) -> Void)?
    }

    public typealias Assemble = @Sendable ([UInt8]) -> [(value: Output, recovered: Bool)]

    private let source: DatagramSource
    private let pingPayload: [UInt8]?
    private let pingIntervalNanos: UInt64
    private let assemble: Assemble
    private let state = Mutex(State())

    public init(
        source: DatagramSource,
        pingPayload: [UInt8]?,
        pingIntervalNanos: UInt64 = 500_000_000,
        assemble: @escaping Assemble
    ) {
        self.source = source
        self.pingPayload = pingPayload
        self.pingIntervalNanos = pingIntervalNanos
        self.assemble = assemble
    }

    public func start(onOutput: (@Sendable (Output) -> Void)? = nil) async {
        let shouldStart = state.withLock { state in
            guard !state.running else { return false }
            state.running = true
            state.onOutput = onOutput
            return true
        }
        guard shouldStart else { return }

        source.start { [weak self] datagram in self?.ingest(datagram) }
        let interval = pingIntervalNanos
        let task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.sendPing()
                try? await Task.sleep(nanoseconds: interval)
            }
        }
        state.withLock { $0.pingTask = task }
    }

    @discardableResult
    public func stop() async -> Stats {
        let task = state.withLock { state in
            state.running = false
            defer { state.pingTask = nil }
            return state.pingTask
        }
        task?.cancel()
        source.stop()
        return await snapshot()
    }

    @discardableResult
    public func run(forSeconds seconds: Double, onOutput: (@Sendable (Output) -> Void)? = nil) async -> Stats {
        await start(onOutput: onOutput)
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        return await stop()
    }

    public func snapshot() async -> Stats {
        state.withLock { $0.stats }
    }

    private func sendPing() {
        let sequence = state.withLock { state -> UInt32? in
            guard state.running else { return nil }
            state.pingSeq &+= 1
            return state.pingSeq
        }
        guard let sequence else { return }
        source.send(RTPPing.datagram(payload: pingPayload, seq: sequence))
    }

    private func ingest(_ bytes: [UInt8]) {
        let outputs = assemble(bytes)
        let callback = state.withLock { state -> (@Sendable (Output) -> Void)? in
            guard state.running else { return nil }
            state.stats.datagrams += 1
            state.stats.bytes += bytes.count
            state.stats.lastActivityNanos = DispatchTime.now().uptimeNanoseconds
            for out in outputs {
                state.stats.outputs += 1
                if out.recovered { state.stats.recovered += 1 }
            }
            return state.onOutput
        }

        for out in outputs { callback?(out.value) }
    }
}

public extension RTPStreamReceiver where Output == AssembledFrame {
    static func video(host: String, port: UInt16, packetSize: Int, pingPayload: [UInt8]?) -> RTPStreamReceiver<AssembledFrame> {
        video(assembler: VideoFrameAssembler(packetSize: packetSize), host: host, port: port, pingPayload: pingPayload)
    }

    static func video(assembler: VideoFrameAssembler, host: String, port: UInt16, pingPayload: [UInt8]?) -> RTPStreamReceiver<AssembledFrame> {
        RTPStreamReceiver(source: NWDatagramSource(host: host, port: port), pingPayload: pingPayload) { datagram in
            guard let frame = try? assembler.ingest(datagram) else { return [] }
            return [(value: frame, recovered: frame.recovered)]
        }
    }
}

public extension RTPStreamReceiver where Output == AudioOpusPacket {
    static func audio(host: String, port: UInt16, pingPayload: [UInt8]?) throws -> RTPStreamReceiver<AudioOpusPacket> {
        let assembler = try AudioStreamAssembler()
        return RTPStreamReceiver(source: NWDatagramSource(host: host, port: port), pingPayload: pingPayload) { datagram in
            assembler.ingest(datagram).map { (value: $0, recovered: $0.recovered) }
        }
    }
}
