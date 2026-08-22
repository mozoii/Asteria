import Foundation
import CoreVideo
import QuartzCore

/// Single-slot exchange between decoder and renderer. Newest frame wins; the renderer blocks briefly for a fresh
/// frame (freshness over completeness) so a near-ready decode lands on the current vsync instead of the next.
public final class LatestFrameHolder: @unchecked Sendable {
    private let condition = NSCondition()
    private var pixelBuffer: CVPixelBuffer?
    private var frameIndex: UInt32 = 0
    private var hasFrame = false
    private var hasFresh = false   // a stored frame not yet taken by takeFresh
    private var delivered = 0
    private var meanDecodeSeconds = 0.0

    public init() {}

    /// Store decoded frame, replacing any previous; `decodeSeconds` feeds the smoothed decode-time readout.
    public func store(_ buffer: CVPixelBuffer, frameIndex: UInt32, decodeSeconds: Double = 0) {
        condition.lock()
        defer { condition.unlock() }
        guard !hasFrame || isNewer(frameIndex, than: self.frameIndex) else { return }
        self.pixelBuffer = buffer
        self.frameIndex = frameIndex
        self.hasFrame = true
        self.hasFresh = true
        self.delivered += 1
        if decodeSeconds > 0 {
            meanDecodeSeconds = meanDecodeSeconds == 0 ? decodeSeconds : meanDecodeSeconds * 0.9 + decodeSeconds * 0.1
        }
        condition.signal()
    }

    /// Compare wrapping frame indices without allowing a late callback to move playback backward.
    private func isNewer(_ candidate: UInt32, than current: UInt32) -> Bool {
        let distance = candidate &- current
        return distance != 0 && distance < 0x8000_0000
    }

    /// Take the frame if one arrived since the last take, waiting up to `maxWait` seconds for one; consumes it.
    /// Returns `nil` on timeout so the caller presents nothing and the last drawable persists.
    public func takeFresh(maxWait seconds: Double) -> (buffer: CVPixelBuffer, frameIndex: UInt32)? {
        condition.lock()
        defer { condition.unlock() }
        if !hasFresh, seconds > 0 {
            let deadline = Date(timeIntervalSinceNow: seconds)
            while !hasFresh {
                if !condition.wait(until: deadline) { break }   // timed out
            }
        }
        guard hasFresh, let pixelBuffer else { return nil }
        hasFresh = false
        return (pixelBuffer, frameIndex)
    }

    /// Total frames delivered (decode-progress counter).
    public func deliveredCount() -> Int {
        condition.lock()
        defer { condition.unlock() }
        return delivered
    }

    /// Smoothed (EWMA) decode latency in milliseconds; 0 until the first timed frame lands.
    public func meanDecodeMillis() -> Double {
        condition.lock()
        defer { condition.unlock() }
        return meanDecodeSeconds * 1000
    }

    /// Current frame if any, without consuming freshness; for inspection and the headless path.
    public func peek() -> (buffer: CVPixelBuffer, frameIndex: UInt32)? {
        condition.lock()
        defer { condition.unlock() }
        guard hasFrame, let pixelBuffer else { return nil }
        return (pixelBuffer, frameIndex)
    }
}
