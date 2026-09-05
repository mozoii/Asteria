/// Frame rate (fps) from a monotonic frame counter plus uptime timestamps. The rate is normalized
/// over the actual elapsed interval so an irregular snapshot cadence can't read as a spike. Returns
/// nil when the interval is unmeasurable so the caller holds its previous value.
public struct FrameRateMeter: Sendable, Equatable {
    private var lastFrames: Int?
    private var lastNanos: UInt64?

    public init() {}

    /// Clears state, so the next sample starts a fresh baseline (new stream session).
    public mutating func reset() {
        self = Self()
    }

    /// Feed the cumulative delivered-frame total and a monotonic timestamp (nanoseconds). Returns the
    /// frame rate for the interval since the previous sample, or nil when the caller should hold its
    /// previous value (first sample, counter restart, or no elapsed time).
    @discardableResult
    public mutating func sample(frames: Int, at nanos: UInt64) -> Double? {
        defer { lastFrames = frames; lastNanos = nanos }
        guard let lastFrames, let lastNanos else { return nil }
        guard frames >= lastFrames else { return nil }   // counter restarted (new session)
        guard nanos > lastNanos else { return nil }      // no time elapsed / clock regression
        let elapsedSeconds = Double(nanos - lastNanos) / 1e9
        return Double(frames - lastFrames) / elapsedSeconds
    }
}
