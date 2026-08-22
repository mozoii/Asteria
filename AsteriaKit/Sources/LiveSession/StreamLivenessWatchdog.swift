import GameStreamProtocol

/// Detects a dead/frozen stream from transport + presentation counters, checked pure and clock-injected for
/// tests. Traffic stall (bytes flat 5 s) wins over frame stall (deliveries flat 3 s, only armed while bytes
/// advance); a stall clock arms on the first sample and any counter advance clears it.
public struct StreamLivenessWatchdog: Sendable {
    public var trafficStallNanos: UInt64
    public var frameStallNanos: UInt64

    private var lastBytes: Int?
    private var lastFrames: Int?
    private var trafficStallStart: UInt64?
    private var frameStallStart: UInt64?

    public init(trafficStallNanos: UInt64 = 5_000_000_000,
                frameStallNanos: UInt64 = 3_000_000_000) {
        self.trafficStallNanos = trafficStallNanos
        self.frameStallNanos = frameStallNanos
    }

    /// Feed one sample; returns the termination reason once a stall crosses its threshold, else nil.
    public mutating func observe(videoBytes: Int, deliveredFrames: Int, now: UInt64) -> TerminationError? {
        defer {
            lastBytes = videoBytes
            lastFrames = deliveredFrames
        }
        let bytesAdvanced = lastBytes.map { videoBytes > $0 } ?? false
        let framesAdvanced = lastFrames.map { deliveredFrames > $0 } ?? false

        trafficStallStart = bytesAdvanced ? nil : (trafficStallStart ?? now)
        if framesAdvanced {
            frameStallStart = nil
        } else if bytesAdvanced {
            frameStallStart = frameStallStart ?? now
        }

        if let start = trafficStallStart, now - start >= trafficStallNanos {
            return .noVideoTraffic
        }
        guard bytesAdvanced, let start = frameStallStart, now - start >= frameStallNanos else { return nil }
        return .noVideoFrame
    }
}
