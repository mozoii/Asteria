import Testing
@testable import GameStreamProtocol

@Suite("InputStats derived metrics")
struct InputStatsTests {
    @Test func coalesceRatioReflectsMerging() {
        var s = InputStats()
        s.eventsEnqueued = 100
        s.packetsSent = 25
        #expect(s.coalesceRatio == 0.75)   // 75% of events merged away
    }

    @Test func coalesceRatioClampsAndHandlesZero() {
        #expect(InputStats().coalesceRatio == 0)   // empty
        var split = InputStats()
        split.eventsEnqueued = 1
        split.packetsSent = 3                       // overflow split
        #expect(split.coalesceRatio == 0)           // clamped ≥ 0
    }

    @Test func ratesUseElapsedWindow() {
        var s = InputStats()
        s.eventsEnqueued = 500
        s.flushes = 250
        s.elapsedNanos = 1_000_000_000             // 1 second
        #expect(s.eventsPerSecond == 500)
        #expect(s.flushesPerSecond == 250)
    }

    @Test func latencyMillisFromNanos() {
        var s = InputStats()
        s.flushes = 2
        s.totalLatencyNanos = 6_000_000            // 6 ms total over 2 flushes
        s.maxLatencyNanos = 4_000_000
        #expect(s.averageLatencyMillis == 3.0)
        #expect(s.maxLatencyMillis == 4.0)
    }

    @Test func zeroFlushesGivesZeroLatency() {
        #expect(InputStats().averageLatencyMillis == 0)
    }
}
