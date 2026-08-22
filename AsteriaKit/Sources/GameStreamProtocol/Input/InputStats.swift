import Foundation

/// Snapshot of input send path health: event coalescing, flush cadence, enqueue rate, enqueue→flush latency.
public struct InputStats: Sendable, Equatable, CustomStringConvertible {
    /// Enqueue calls made by the capture layer (discrete events + continuous updates).
    public var eventsEnqueued = 0
    /// Packets handed to the transport.
    public var packetsSent = 0
    /// Non-empty flush ticks (each drains the buffer into ≥1 packet).
    public var flushes = 0
    /// Worst enqueue→flush latency observed (oldest pending event's age at flush), nanoseconds.
    public var maxLatencyNanos: UInt64 = 0
    /// Sum of per-flush latencies (oldest pending event's age), nanoseconds — for the average.
    public var totalLatencyNanos: UInt64 = 0
    /// Wall time spanned since the first enqueue, nanoseconds (for the rate math).
    public var elapsedNanos: UInt64 = 0

    public init() {}

    /// Fraction of enqueued events merged away by coalescing: 1 − packets/events, clamped to [0,1].
    public var coalesceRatio: Double {
        guard eventsEnqueued > 0 else { return 0 }
        return min(1, max(0, 1 - Double(packetsSent) / Double(eventsEnqueued)))
    }
    /// Enqueued events per second over the elapsed window.
    public var eventsPerSecond: Double {
        elapsedNanos == 0 ? 0 : Double(eventsEnqueued) * 1e9 / Double(elapsedNanos)
    }
    /// Non-empty flushes per second (the flush cadence the host actually sees).
    public var flushesPerSecond: Double {
        elapsedNanos == 0 ? 0 : Double(flushes) * 1e9 / Double(elapsedNanos)
    }
    /// Average enqueue→flush latency, milliseconds.
    public var averageLatencyMillis: Double {
        flushes == 0 ? 0 : Double(totalLatencyNanos) / Double(flushes) / 1e6
    }
    /// Worst enqueue→flush latency, milliseconds.
    public var maxLatencyMillis: Double { Double(maxLatencyNanos) / 1e6 }

    public var description: String {
        String(format: "events:%d sent:%d coalesce:%.0f%% %.0fev/s flush:%.0f/s lat avg:%.2fms max:%.2fms",
               eventsEnqueued, packetsSent, coalesceRatio * 100, eventsPerSecond, flushesPerSecond,
               averageLatencyMillis, maxLatencyMillis)
    }
}

/// Thread-safe accumulator for `InputStats`. Lock-based for cheap enqueue path; clock is injectable for deterministic tests.
public final class InputStatsTracker: @unchecked Sendable {
    private let lock = NSLock()
    private let now: @Sendable () -> UInt64
    private var eventsEnqueued = 0
    private var packetsSent = 0
    private var flushes = 0
    private var maxLatency: UInt64 = 0
    private var totalLatency: UInt64 = 0
    private var startNanos: UInt64?

    public init(now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) {
        self.now = now
    }

    public func recordEnqueue(_ count: Int = 1) {
        lock.lock(); defer { lock.unlock() }
        if startNanos == nil { startNanos = now() }
        eventsEnqueued += count
    }

    public func recordFlush(packets: Int, latencyNanos: UInt64) {
        guard packets > 0 else { return }
        lock.lock(); defer { lock.unlock() }
        if startNanos == nil { startNanos = now() }
        packetsSent += packets
        flushes += 1
        totalLatency += latencyNanos
        if latencyNanos > maxLatency { maxLatency = latencyNanos }
    }

    public func snapshot() -> InputStats {
        lock.lock(); defer { lock.unlock() }
        var s = InputStats()
        s.eventsEnqueued = eventsEnqueued
        s.packetsSent = packetsSent
        s.flushes = flushes
        s.maxLatencyNanos = maxLatency
        s.totalLatencyNanos = totalLatency
        if let start = startNanos { let n = now(); s.elapsedNanos = n >= start ? n - start : 0 }
        return s
    }
}
