public struct FoundationABRFrameCounters: Equatable, Sendable {
    public let decoded: Int
    public let delivered: Int
    public let networkLost: Int
    public let dropped: Int

    public init(decoded: Int, delivered: Int, networkLost: Int, dropped: Int) {
        self.decoded = decoded
        self.delivered = delivered
        self.networkLost = networkLost
        self.dropped = dropped
    }
}

public struct FoundationABRSnapshot: Equatable, Sendable {
    public let time: Double
    public let frames: FoundationABRFrameCounters
    public let videoBytes: Int
    public let rttMillis: Int

    public init(time: Double, frames: FoundationABRFrameCounters,
                videoBytes: Int, rttMillis: Int) {
        self.time = time
        self.frames = frames
        self.videoBytes = videoBytes
        self.rttMillis = rttMillis
    }
}

public struct FoundationABRSample: Equatable, Sendable {
    public let packetLossPercent: Double
    public let rttMillis: Int
    public let decodeFps: Int
    public let droppedFrames: Int
    public let currentBitrateKbps: Int
}

public struct FoundationABRSampler: Equatable, Sendable {
    private var previous: FoundationABRSnapshot?

    public init() {}

    public mutating func sample(_ current: FoundationABRSnapshot) -> FoundationABRSample? {
        defer { previous = current }
        guard let previous, countersDidNotReset(from: previous, to: current) else { return nil }
        let seconds = current.time - previous.time
        guard seconds > 0 else { return nil }

        let delivered = current.frames.delivered - previous.frames.delivered
        let lost = current.frames.networkLost - previous.frames.networkLost
        let expected = delivered + lost
        let loss = expected > 0 ? Double(lost) / Double(expected) * 100 : 0
        let decoded = Double(current.frames.decoded - previous.frames.decoded) / seconds
        let dropped = current.frames.dropped - previous.frames.dropped
        let bytes = Double(current.videoBytes - previous.videoBytes)
        let bitrate = bytes * 8 / seconds / 1_000

        return FoundationABRSample(
            packetLossPercent: loss,
            rttMillis: max(0, current.rttMillis),
            decodeFps: max(0, Int(decoded.rounded())),
            droppedFrames: max(0, dropped),
            currentBitrateKbps: max(0, Int(bitrate.rounded())))
    }

    private func countersDidNotReset(
        from previous: FoundationABRSnapshot, to current: FoundationABRSnapshot
    ) -> Bool {
        current.frames.decoded >= previous.frames.decoded
            && current.frames.delivered >= previous.frames.delivered
            && current.frames.networkLost >= previous.frames.networkLost
            && current.frames.dropped >= previous.frames.dropped
            && current.videoBytes >= previous.videoBytes
    }
}
