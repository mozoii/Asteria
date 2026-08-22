import Foundation

/// Snapshot of video pipeline health: decode outcomes, FEC recovery, network loss, and recovery requests.
public struct VideoStats: Sendable, Equatable {
    /// Frames dispatched to the decoder (`submit` returned `.ok`).
    public var decoded = 0
    /// Submissions that couldn't decode yet and asked for a keyframe (`.needsIdr`).
    public var needsIdr = 0
    /// Submissions dropped as malformed (`.dropped`).
    public var dropped = 0
    /// Delivered frames that needed Reed-Solomon FEC recovery.
    public var recovered = 0
    /// Frames lost in transit (gaps in the frame-index stream).
    public var networkLost = 0
    /// Recovery requests (IDR or RFI) sent to the host.
    public var idrRequests = 0

    public init() {}

    /// Total frames handed to the decoder (regardless of outcome).
    public var delivered: Int { decoded + needsIdr + dropped }
    /// Fraction of the host's frames that never arrived: lost / (delivered + lost).
    public var lossRate: Double {
        let total = delivered + networkLost
        return total == 0 ? 0 : Double(networkLost) / Double(total)
    }
}

/// Thread-safe accumulator for `VideoStats`; lock-guarded for cheap non-async reads.
public final class VideoStatsTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var stats = VideoStats()

    public init() {}

    public func record(_ status: SubmitStatus) {
        lock.lock(); defer { lock.unlock() }
        switch status {
        case .ok: stats.decoded += 1
        case .needsIdr: stats.needsIdr += 1
        case .dropped: stats.dropped += 1
        }
    }

    public func recordRecovered() { lock.lock(); stats.recovered += 1; lock.unlock() }
    public func recordNetworkLost(_ n: Int) { lock.lock(); stats.networkLost += n; lock.unlock() }
    public func recordIdrRequest() { lock.lock(); stats.idrRequests += 1; lock.unlock() }

    public func snapshot() -> VideoStats { lock.lock(); defer { lock.unlock() }; return stats }
}
