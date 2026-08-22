import Testing
import Foundation
import CoreVideo
@testable import VideoEngine

@Suite("LatestFrameHolder take/consume")
struct LatestFrameHolderTests {
    static func makeBuffer() -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 16, 16,
                            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil, &pb)
        return pb!
    }

    @Test("takeFresh returns the frame once, then nil until a new store")
    func consumesFreshFrame() {
        let holder = LatestFrameHolder()
        holder.store(Self.makeBuffer(), frameIndex: 7)
        #expect(holder.takeFresh(maxWait: 0)?.frameIndex == 7)
        #expect(holder.takeFresh(maxWait: 0) == nil)   // already consumed
    }

    @Test("takeFresh on an empty holder returns nil without blocking")
    func emptyReturnsNil() {
        #expect(LatestFrameHolder().takeFresh(maxWait: 0) == nil)
    }

    @Test("newest store wins; an unconsumed frame is overwritten")
    func latestWins() {
        let holder = LatestFrameHolder()
        holder.store(Self.makeBuffer(), frameIndex: 10)
        holder.store(Self.makeBuffer(), frameIndex: 11)
        #expect(holder.takeFresh(maxWait: 0)?.frameIndex == 11)
    }

    @Test("a late decode callback cannot replace a newer frame")
    func ignoresStaleFrame() {
        let holder = LatestFrameHolder()
        holder.store(Self.makeBuffer(), frameIndex: 12)
        holder.store(Self.makeBuffer(), frameIndex: 11)
        #expect(holder.takeFresh(maxWait: 0)?.frameIndex == 12)
    }

    @Test("peek inspects without consuming freshness")
    func peekIsNonConsuming() {
        let holder = LatestFrameHolder()
        holder.store(Self.makeBuffer(), frameIndex: 3)
        #expect(holder.peek()?.frameIndex == 3)
        #expect(holder.peek()?.frameIndex == 3)
        #expect(holder.takeFresh(maxWait: 0)?.frameIndex == 3)   // peek left the fresh frame intact
    }

    /// Lock-protected slot so a detached thread can hand its takeFresh result back.
    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: UInt32?
        var value: UInt32? { lock.lock(); defer { lock.unlock() }; return stored }
        func set(_ newValue: UInt32?) { lock.lock(); stored = newValue; lock.unlock() }
    }

    @Test("takeFresh blocks until a frame arrives within the wait window")
    func blocksForArrival() {
        let holder = LatestFrameHolder()
        // Semaphore handoff, not a sleep: the waiter announces itself before blocking, only then the producer
        // stores. Dedicated threads: blocking waiters starve shared pools when the suite runs in parallel.
        let waiterEntered = DispatchSemaphore(value: 0)
        let releaseProducer = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0)
        let delivered = ResultBox()

        Thread.detachNewThread {
            releaseProducer.wait()
            holder.store(Self.makeBuffer(), frameIndex: 99)
        }
        Thread.detachNewThread {
            waiterEntered.signal()
            delivered.set(holder.takeFresh(maxWait: 5.0)?.frameIndex)
            done.signal()
        }

        _ = waiterEntered.wait(timeout: .now() + 5)
        releaseProducer.signal()

        _ = done.wait(timeout: .now() + 10)
        #expect(delivered.value == 99)
    }

    @Test("deliveredCount counts every store")
    func deliveredCounts() {
        let holder = LatestFrameHolder()
        holder.store(Self.makeBuffer(), frameIndex: 1)
        holder.store(Self.makeBuffer(), frameIndex: 2)
        #expect(holder.deliveredCount() == 2)
    }
}
