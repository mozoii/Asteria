import Foundation
import Testing
@testable import GameStreamProtocol

private final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var t: UInt64 = 0
    var now: @Sendable () -> UInt64 { { [self] in lock.lock(); defer { lock.unlock() }; return t } }
    func advance(_ d: UInt64) { lock.lock(); t += d; lock.unlock() }
    func set(_ v: UInt64) { lock.lock(); t = v; lock.unlock() }
}

private actor StatsMockTransport: InputTransport {
    func send(_ message: ControlMessage.Message, channel: UInt8, reliable: Bool) async throws {}
    func flush() async {}
}

@Suite("InputStatsTracker / sender integration")
struct InputStatsTrackerTests {
    @Test func trackerAccumulatesWithInjectedClock() {
        let clock = FakeClock()
        let t = InputStatsTracker(now: clock.now)
        t.recordEnqueue()
        t.recordEnqueue(2)
        clock.advance(2_000_000)
        t.recordFlush(packets: 1, latencyNanos: 2_000_000)
        t.recordFlush(packets: 0, latencyNanos: 999)
        clock.advance(2_000_000)

        let s = t.snapshot()
        #expect(s.eventsEnqueued == 3)
        #expect(s.packetsSent == 1)
        #expect(s.flushes == 1)
        #expect(s.maxLatencyNanos == 2_000_000)
        #expect(s.totalLatencyNanos == 2_000_000)
        #expect(s.elapsedNanos == 4_000_000)
        #expect(s.eventsPerSecond == 750)   // 3 events / 0.004 s
    }

    @Test func senderRecordsCoalesceAndLatency() async {
        let clock = FakeClock()
        let sender = InputSender(transport: StatsMockTransport(), clock: clock.now)
        sender.mouseMoveRelative(deltaX: 1, deltaY: 0)   // oldest stamped at t = 0
        sender.mouseMoveRelative(deltaX: 1, deltaY: 0)
        sender.mouseMoveRelative(deltaX: 1, deltaY: 0)   // 3 events, coalesce to 1 packet
        clock.advance(3_000_000)                          // 3 ms before the flush
        await sender.flushOnce()

        let s = sender.stats
        #expect(s.eventsEnqueued == 3)
        #expect(s.packetsSent == 1)
        #expect(s.flushes == 1)
        #expect(s.maxLatencyNanos == 3_000_000)
        #expect(s.coalesceRatio > 0.6)
    }

    @Test func enqueueStampLaterThanFlushSaturatesLatency() async {
        let clock = FakeClock()
        clock.set(100)
        let sender = InputSender(transport: StatsMockTransport(), clock: clock.now)
        sender.mouseMoveRelative(deltaX: 1, deltaY: 0)
        clock.set(50)
        await sender.flushOnce()

        let s = sender.stats
        #expect(s.flushes == 1)
        #expect(s.maxLatencyNanos == 0)
        #expect(s.totalLatencyNanos == 0)
    }

    @Test func emptyFlushRecordsNothing() async {
        let clock = FakeClock()
        let sender = InputSender(transport: StatsMockTransport(), clock: clock.now)
        await sender.flushOnce()
        let s = sender.stats
        #expect(s.flushes == 0)
        #expect(s.packetsSent == 0)
        #expect(s.eventsEnqueued == 0)
    }
}
