import Testing
@testable import VideoEngine

@Suite("Recovery controller (IDR / RFI policy)")
struct RecoveryControllerTests {
    @Test("requests an IDR while the decoder has no keyframe, throttled to one outstanding")
    func requestsIdrBeforeKeyframe() {
        var r = RecoveryController()
        #expect(r.observe(frameIndex: 1, status: .needsIdr) == .idr)
        #expect(r.observe(frameIndex: 2, status: .needsIdr) == nil)   // throttle blocks second request
        #expect(r.observe(frameIndex: 3, status: .needsIdr) == nil)
    }

    @Test("clean contiguous decoding asks for nothing")
    func cleanStreamIsQuiet() {
        var r = RecoveryController()
        for i in UInt32(1)...10 { #expect(r.observe(frameIndex: i, status: .ok) == nil) }
    }

    @Test("a frame-index gap requests an IDR when RFI is unavailable")
    func gapRequestsIdrWithoutRfi() {
        var r = RecoveryController(referenceInvalidationSupported: false)
        #expect(r.observe(frameIndex: 1, status: .ok) == nil)
        #expect(r.observe(frameIndex: 2, status: .ok) == nil)
        #expect(r.observe(frameIndex: 5, status: .ok) == .idr)        // frames 3 & 4 lost
    }

    @Test("a frame-index gap requests reference-frame invalidation of the lost range when RFI is available")
    func gapRequestsRfiWhenSupported() {
        var r = RecoveryController(referenceInvalidationSupported: true)
        #expect(r.observe(frameIndex: 1, status: .ok) == nil)
        #expect(r.observe(frameIndex: 2, status: .ok) == nil)
        #expect(r.observe(frameIndex: 5, status: .ok) == .invalidateReferenceFrames(first: 3, last: 4))
    }

    @Test("a decode failure mid-stream requests an IDR")
    func decodeFailureRequestsIdr() {
        var r = RecoveryController()
        #expect(r.observe(frameIndex: 1, status: .ok) == nil)
        #expect(r.observe(frameIndex: 2, status: .needsIdr) == .idr)
    }

    @Test("the throttle clears after a clean contiguous frame, re-arming for the next loss")
    func throttleClearsOnRecovery() {
        var r = RecoveryController()
        #expect(r.observe(frameIndex: 1, status: .ok) == nil)
        #expect(r.observe(frameIndex: 3, status: .ok) == .idr)        // gap → request
        #expect(r.observe(frameIndex: 4, status: .ok) == nil)        // recovered & contiguous → clears
        #expect(r.observe(frameIndex: 6, status: .ok) == .idr)        // a fresh gap re-requests
    }
}

@Suite("Video stats tracker")
struct VideoStatsTests {
    @Test("aggregates decode outcomes, recovery, loss, and IDR requests")
    func aggregates() {
        let t = VideoStatsTracker()
        t.record(.ok); t.record(.ok); t.record(.needsIdr); t.record(.dropped)
        t.recordRecovered()
        t.recordNetworkLost(3)
        t.recordIdrRequest(); t.recordIdrRequest()

        let s = t.snapshot()
        #expect(s.decoded == 2)
        #expect(s.needsIdr == 1)
        #expect(s.dropped == 1)
        #expect(s.recovered == 1)
        #expect(s.networkLost == 3)
        #expect(s.idrRequests == 2)
        #expect(s.delivered == 4)            // ok + needsIdr + dropped
    }

    @Test("loss rate is lost / (delivered + lost)")
    func lossRate() {
        let t = VideoStatsTracker()
        for _ in 0..<7 { t.record(.ok) }     // 7 delivered
        t.recordNetworkLost(3)               // 3 lost
        #expect(abs(t.snapshot().lossRate - 0.3) < 1e-9)

        #expect(VideoStats().lossRate == 0)  // zero frames safe
    }
}
