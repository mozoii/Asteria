import Synchronization

/// Lock-free SPSC ring of interleaved Float PCM for the render callback; all sizes are in samples.
public final class PCMRingBuffer: @unchecked Sendable {
    private let storage: UnsafeMutablePointer<Float>
    public let capacity: Int
    public let primeThreshold: Int
    /// Steady-state depth ceiling; a write past this drops the oldest samples.
    public let depthLimit: Int

    private let writeIndex = Atomic<Int>(0)
    private let readIndex = Atomic<Int>(0)
    private let primed = Atomic<Bool>(false)
    private let underruns = Atomic<Int>(0)
    private let overruns = Atomic<Int>(0)
    private let droppedSamples = Atomic<Int>(0)

    /// A 30 ms cushion absorbs packet jitter; an 80 ms ceiling retains recovered packet bursts.
    public init(channelCount: Int, sampleRate: Int = 48000, primeMilliseconds: Int = 30,
                maxDepthMilliseconds: Int = 80, maxFrameSamplesPerChannel: Int = 5760) {
        let perMillisecond = max(1, sampleRate * channelCount / 1000)
        self.primeThreshold = max(1, primeMilliseconds * perMillisecond)
        self.depthLimit = max(primeThreshold, maxDepthMilliseconds * perMillisecond)
        // Headroom for one max-size frame guarantees any single write fits after dropping to the limit.
        self.capacity = depthLimit + maxFrameSamplesPerChannel * channelCount
        self.storage = .allocate(capacity: capacity)
        storage.initialize(repeating: 0, count: capacity)
    }

    deinit {
        storage.deinitialize(count: capacity)
        storage.deallocate()
    }

    /// Producer: enqueue interleaved samples, dropping the oldest if the write would exceed the depth limit.
    public func write(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        let count = samples.count
        let writeAt = writeIndex.load(ordering: .relaxed)
        var read = readIndex.load(ordering: .acquiring)

        if (writeAt - read) + count > depthLimit {
            let drop = (writeAt - read) - max(0, depthLimit - count)
            if drop > 0 {
                readIndex.wrappingAdd(drop, ordering: .acquiringAndReleasing)
                overruns.wrappingAdd(1, ordering: .relaxed)
                droppedSamples.wrappingAdd(drop, ordering: .relaxed)
                read += drop
            }
        }

        samples.withUnsafeBufferPointer { source in
            var done = 0
            var slot = writeAt % capacity
            while done < count {
                let chunk = min(count - done, capacity - slot)
                (storage + slot).update(from: source.baseAddress! + done, count: chunk)
                done += chunk
                slot = (slot + chunk) % capacity
            }
        }
        writeIndex.store(writeAt + count, ordering: .releasing)

        if !primed.load(ordering: .relaxed), (writeAt + count) - read >= primeThreshold {
            primed.store(true, ordering: .releasing)
        }
    }

    /// Consumer (render callback): fill `out` with `count` samples; silence while priming or on underrun.
    public func read(into out: UnsafeMutableBufferPointer<Float>, count: Int) {
        let destination = out.baseAddress!
        guard primed.load(ordering: .acquiring) else {
            destination.update(repeating: 0, count: count)
            return
        }
        let writeAt = writeIndex.load(ordering: .acquiring)
        let read = readIndex.load(ordering: .relaxed)
        let take = min(writeAt - read, count)

        var done = 0
        var slot = read % capacity
        while done < take {
            let chunk = min(take - done, capacity - slot)
            (destination + done).update(from: storage + slot, count: chunk)
            done += chunk
            slot = (slot + chunk) % capacity
        }
        if take < count {
            (destination + take).update(repeating: 0, count: count - take)
            underruns.wrappingAdd(1, ordering: .relaxed)
            if take == 0 { primed.store(false, ordering: .releasing) }
        }
        readIndex.store(read + take, ordering: .releasing)
    }

    public var isPrimed: Bool { primed.load(ordering: .relaxed) }
    public var depth: Int { writeIndex.load(ordering: .acquiring) - readIndex.load(ordering: .acquiring) }

    public func stats() -> AudioRenderStats {
        AudioRenderStats(underruns: underruns.load(ordering: .relaxed),
                         overruns: overruns.load(ordering: .relaxed),
                         droppedSamples: droppedSamples.load(ordering: .relaxed),
                         depth: depth)
    }
}
