/// Decides when to request recovery (IDR or RFI) based on decode status and frame-index gaps.
public struct RecoveryController {
    public enum Request: Equatable, Sendable {
        case idr
        case invalidateReferenceFrames(first: UInt32, last: UInt32)
    }

    private let referenceInvalidationSupported: Bool
    /// Next expected frame index; gap detection via frameIndex > nextExpectedFrame.
    private var nextExpectedFrame: UInt32?
    /// One request at a time; cleared when stream recovers (clean, contiguous decode).
    private var requestOutstanding = false

    public init(referenceInvalidationSupported: Bool = false) {
        self.referenceInvalidationSupported = referenceInvalidationSupported
    }

    /// Observe submission outcome; return recovery request or `nil` if none/already outstanding.
    public mutating func observe(frameIndex: UInt32, status: SubmitStatus) -> Request? {
        let gapStart = nextExpectedFrame
        let isGap = gapStart.map { frameIndex > $0 } ?? false
        nextExpectedFrame = frameIndex + 1

        // Clean contiguous decode: reference chain is intact again.
        if status == .ok, !isGap {
            requestOutstanding = false
            return nil
        }

        // Reference broken: request recovery once.
        guard !requestOutstanding else { return nil }
        requestOutstanding = true

        if referenceInvalidationSupported, isGap, let first = gapStart, frameIndex > first {
            return .invalidateReferenceFrames(first: first, last: frameIndex - 1)
        }
        return .idr
    }
}
