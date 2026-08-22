import GameStreamProtocol

/// Sink for recovery requests (IDR / RFI) from `DecodePump`. Decouples decode logic from control-stream wiring.
public protocol RecoverySink: Sendable {
    func requestRecovery(_ request: RecoveryController.Request) async
}

/// Per-frame decode + loss-recovery loop: submit frames to renderer, track stats, emit recovery requests when reference chain breaks. Testable without live host.
public actor DecodePump {
    private let renderer: DecoderRenderer
    private let sink: RecoverySink
    private let stats: VideoStatsTracker
    private var recovery: RecoveryController
    /// Highest frame index seen; a jump past `last + 1` means the in-between frames were lost in transit.
    private var lastFrameIndex: UInt32?

    private let stream: AsyncStream<AssembledFrame>
    private nonisolated let continuation: AsyncStream<AssembledFrame>.Continuation
    private var drain: Task<Void, Never>?

    public init(renderer: DecoderRenderer, sink: RecoverySink, stats: VideoStatsTracker,
                referenceInvalidationSupported: Bool) {
        self.renderer = renderer
        self.sink = sink
        self.stats = stats
        self.recovery = RecoveryController(referenceInvalidationSupported: referenceInvalidationSupported)
        let (stream, continuation) = AsyncStream<AssembledFrame>.makeStream()
        self.stream = stream
        self.continuation = continuation
    }

    /// Start draining frames to renderer. Idempotent.
    public func start() {
        guard drain == nil else { return }
        drain = Task { [stream] in
            for await frame in stream { await self.handle(frame) }
        }
    }

    /// Feed one reassembled frame. `nonisolated` so UDP receiver's callback can enqueue without awaiting.
    public nonisolated func yield(_ frame: AssembledFrame) {
        continuation.yield(frame)
    }

    /// Finish feed and await drain. Idempotent.
    public func finish() async {
        continuation.finish()
        await drain?.value
        drain = nil
    }

    private func handle(_ frame: AssembledFrame) async {
        if let last = lastFrameIndex, frame.frameIndex > last + 1 {
            stats.recordNetworkLost(Int(frame.frameIndex - last - 1))
        }
        lastFrameIndex = frame.frameIndex

        let status = await renderer.submit(frame)
        stats.record(status)
        if frame.recovered { stats.recordRecovered() }

        // Ask the host to repair the reference chain when decode fails or frames were lost.
        if let request = recovery.observe(frameIndex: frame.frameIndex, status: status) {
            stats.recordIdrRequest()
            await sink.requestRecovery(request)
        }
    }
}
