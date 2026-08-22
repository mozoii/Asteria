import Testing
import GameStreamProtocol
@testable import VideoEngine

@Suite("DecodePump")
struct DecodePumpTests {
    /// Returns scripted statuses in order; records submitted frame indices.
    private actor ScriptedRenderer: DecoderRenderer {
        private var statuses: [SubmitStatus]
        private(set) var submitted: [UInt32] = []
        init(_ statuses: [SubmitStatus]) { self.statuses = statuses }
        func submit(_ frame: AssembledFrame) async -> SubmitStatus {
            submitted.append(frame.frameIndex)
            return statuses.isEmpty ? .ok : statuses.removeFirst()
        }
        func stop() async {}
    }

    /// Captures recovery requests emitted by the pump.
    private actor CapturingSink: RecoverySink {
        private(set) var requests: [RecoveryController.Request] = []
        func requestRecovery(_ request: RecoveryController.Request) async { requests.append(request) }
    }

    private func frame(_ index: UInt32, recovered: Bool = false) -> AssembledFrame {
        AssembledFrame(frameIndex: index, data: [], recovered: recovered)
    }

    /// Pump a frame sequence and return stats, recovery requests, and submit order.
    private func run(frames: [AssembledFrame], statuses: [SubmitStatus],
                     rfi: Bool) async -> (stats: VideoStats,
                                          requests: [RecoveryController.Request],
                                          submitted: [UInt32]) {
        let renderer = ScriptedRenderer(statuses)
        let sink = CapturingSink()
        let stats = VideoStatsTracker()
        let pump = DecodePump(renderer: renderer, sink: sink, stats: stats,
                              referenceInvalidationSupported: rfi)
        await pump.start()
        for f in frames { pump.yield(f) }
        await pump.finish()
        return (stats.snapshot(), await sink.requests, await renderer.submitted)
    }

    @Test("contiguous clean frames decode in order with no recovery requests")
    func cleanStream() async {
        let r = await run(frames: [frame(0), frame(1), frame(2)],
                          statuses: [.ok, .ok, .ok], rfi: false)
        #expect(r.submitted == [0, 1, 2])
        #expect(r.stats.decoded == 3)
        #expect(r.stats.networkLost == 0)
        #expect(r.stats.idrRequests == 0)
        #expect(r.requests.isEmpty)
    }

    @Test("a frame-index gap with RFI supported invalidates the lost range")
    func gapRequestsRFI() async {
        let r = await run(frames: [frame(0), frame(3)], statuses: [.ok, .ok], rfi: true)
        #expect(r.stats.networkLost == 2)
        #expect(r.stats.idrRequests == 1)
        #expect(r.requests == [.invalidateReferenceFrames(first: 1, last: 2)])
    }

    @Test("a frame-index gap without RFI requests a full IDR")
    func gapRequestsIdrWithoutRFI() async {
        let r = await run(frames: [frame(0), frame(3)], statuses: [.ok, .ok], rfi: false)
        #expect(r.stats.networkLost == 2)
        #expect(r.requests == [.idr])
    }

    @Test("a decode failure requests a full IDR")
    func decodeFailureRequestsIdr() async {
        let r = await run(frames: [frame(0), frame(1)], statuses: [.ok, .needsIdr], rfi: false)
        #expect(r.stats.needsIdr == 1)
        #expect(r.requests == [.idr])
    }

    @Test("FEC-recovered frames are counted")
    func countsRecovered() async {
        let r = await run(frames: [frame(0, recovered: true), frame(1, recovered: true)],
                          statuses: [.ok, .ok], rfi: false)
        #expect(r.stats.recovered == 2)
    }
}
