import Testing
import GameStreamProtocol
@testable import LiveSession

@Suite("Stream liveness watchdog")
struct StreamLivenessWatchdogTests {
    private let second: UInt64 = 1_000_000_000

    @Test("video bytes flat for 5s trigger noVideoTraffic")
    func bytesFlatFiveSeconds() {
        var w = StreamLivenessWatchdog()
        #expect(w.observe(videoBytes: 10_000, deliveredFrames: 60, now: 0) == nil)
        #expect(w.observe(videoBytes: 10_000, deliveredFrames: 60, now: 4 * second) == nil)
        #expect(w.observe(videoBytes: 10_000, deliveredFrames: 60, now: 5 * second) == .noVideoTraffic)
    }

    @Test("video bytes advancing but deliveries flat for 3s trigger noVideoFrame")
    func frameStallWhileBytesAdvance() {
        var w = StreamLivenessWatchdog()
        #expect(w.observe(videoBytes: 0, deliveredFrames: 0, now: 0) == nil)
        #expect(w.observe(videoBytes: 100, deliveredFrames: 0, now: 1 * second) == nil)
        #expect(w.observe(videoBytes: 200, deliveredFrames: 0, now: 3 * second) == nil)
        #expect(w.observe(videoBytes: 300, deliveredFrames: 0, now: 4 * second) == .noVideoFrame)
    }

    @Test("healthy progression stays silent")
    func healthyProgression() {
        var w = StreamLivenessWatchdog()
        for sample in 1...6 {
            let n = UInt64(sample) * second
            #expect(w.observe(videoBytes: 100 * sample, deliveredFrames: 10 * sample, now: n) == nil)
        }
    }

    @Test("deliveries advancing clear the frame stall clock")
    func frameAdvanceResetsClock() {
        var w = StreamLivenessWatchdog()
        #expect(w.observe(videoBytes: 0, deliveredFrames: 0, now: 0) == nil)
        #expect(w.observe(videoBytes: 100, deliveredFrames: 10, now: 1 * second) == nil)
        #expect(w.observe(videoBytes: 200, deliveredFrames: 10, now: 2 * second) == nil)
        #expect(w.observe(videoBytes: 300, deliveredFrames: 20, now: 3 * second) == nil)
        #expect(w.observe(videoBytes: 400, deliveredFrames: 20, now: 4 * second) == nil)
        #expect(w.observe(videoBytes: 500, deliveredFrames: 20, now: 6 * second) == nil)
        #expect(w.observe(videoBytes: 600, deliveredFrames: 20, now: 7 * second) == .noVideoFrame)
    }

    @Test("traffic beats frame stall when both are exceeding thresholds")
    func trafficStallWins() {
        var w = StreamLivenessWatchdog()
        #expect(w.observe(videoBytes: 0, deliveredFrames: 0, now: 0) == nil)
        #expect(w.observe(videoBytes: 0, deliveredFrames: 0, now: 5 * second) == .noVideoTraffic)
    }

    @Test("a byte advance after a partial stall resets the traffic clock")
    func trafficResetAfterPartialStall() {
        var w = StreamLivenessWatchdog()
        #expect(w.observe(videoBytes: 0, deliveredFrames: 0, now: 0) == nil)
        #expect(w.observe(videoBytes: 0, deliveredFrames: 0, now: 4 * second) == nil)
        #expect(w.observe(videoBytes: 10, deliveredFrames: 0, now: 5 * second) == nil)   // advance clears the clock
        #expect(w.observe(videoBytes: 10, deliveredFrames: 0, now: 9 * second) == nil)  // first flat sample restarts it
        #expect(w.observe(videoBytes: 10, deliveredFrames: 0, now: 14 * second) == .noVideoTraffic)
    }
}
