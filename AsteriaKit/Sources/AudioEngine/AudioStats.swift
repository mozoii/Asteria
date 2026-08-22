import Foundation

/// Snapshot of audio pipeline health: decode-side counters plus render-side ring metrics.
public struct AudioStats: Sendable, Equatable {
    /// Opus packets handed to the decoder.
    public var packetsDecoded = 0
    /// Per-channel samples produced by the decoder.
    public var samplesDecoded = 0
    /// Frames synthesised by packet-loss concealment for unrecovered gaps.
    public var concealed = 0
    /// Packets delivered via Reed-Solomon FEC recovery.
    public var fecRecovered = 0
    /// Packets dropped as late/duplicate, or beyond the concealment cap.
    public var dropped = 0
    /// Render-thread ring health; supplied by the renderer, not the decode side.
    public var render = AudioRenderStats()

    public init() {}
}

/// Thread-safe accumulator for the decode-side of `AudioStats`; lock-guarded for cheap non-async reads.
public final class AudioStatsTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var stats = AudioStats()

    public init() {}

    public func recordDecoded(samples: Int) {
        lock.lock(); defer { lock.unlock() }
        stats.packetsDecoded += 1
        stats.samplesDecoded += samples
    }

    public func recordConcealed(_ count: Int) { lock.lock(); stats.concealed += count; lock.unlock() }
    public func recordFecRecovered() { lock.lock(); stats.fecRecovered += 1; lock.unlock() }
    public func recordDropped(_ count: Int) { lock.lock(); stats.dropped += count; lock.unlock() }

    /// Decode-side snapshot; the `render` field is left for the renderer to fill.
    public func snapshot() -> AudioStats { lock.lock(); defer { lock.unlock() }; return stats }
}
