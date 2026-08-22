import Testing
@testable import AudioEngine

@Suite("PCMRingBuffer")
struct PCMRingBufferTests {
    static func make() -> PCMRingBuffer {
        PCMRingBuffer(channelCount: 1, sampleRate: 1000, primeMilliseconds: 4,
                      maxDepthMilliseconds: 10, maxFrameSamplesPerChannel: 8)
    }

    static func read(_ ring: PCMRingBuffer, _ count: Int) -> [Float] {
        var out = [Float](repeating: -1, count: count)
        out.withUnsafeMutableBufferPointer { ring.read(into: $0, count: count) }
        return out
    }

    @Test func silenceUntilPrimed() {
        let ring = Self.make()
        #expect(!ring.isPrimed)
        #expect(Self.read(ring, 4) == [0, 0, 0, 0])
        ring.write([1, 2, 3])                       // below prime threshold (4)
        #expect(!ring.isPrimed)
        #expect(Self.read(ring, 3) == [0, 0, 0])    // priming read doesn't consume
        ring.write([4])                             // crosses threshold
        #expect(ring.isPrimed)
        #expect(Self.read(ring, 4) == [1, 2, 3, 4]) // accumulated data, FIFO
    }

    @Test func underrunEmitsSilenceAndCounts() {
        let ring = Self.make()
        ring.write([1, 2, 3, 4])
        #expect(Self.read(ring, 2) == [1, 2])
        #expect(Self.read(ring, 4) == [3, 4, 0, 0]) // only 2 available -> silence remainder
        #expect(ring.stats().underruns == 1)
    }

    @Test func overrunDropsOldest() {
        let ring = Self.make()
        ring.write([1, 2, 3, 4, 5, 6, 7, 8])        // depth 8 <= limit 10, primed
        ring.write([9, 10, 11, 12, 13, 14])         // 8+6 > 10 -> drop oldest down
        let stats = ring.stats()
        #expect(stats.overruns == 1)
        #expect(stats.droppedSamples == 4)          // drop to depthLimit-count = 4, i.e. drop 4
        #expect(ring.depth == 10)
        #expect(Self.read(ring, 10) == [5, 6, 7, 8, 9, 10, 11, 12, 13, 14]) // newest retained
    }

    @Test func wrapsAroundPreservingOrder() {
        let ring = Self.make()                       // capacity 18
        var expected: Float = 1
        ring.write([1, 2, 3, 4])
        #expect(ring.isPrimed)
        // Many small write/read cycles push indices well past capacity.
        for _ in 0..<20 {
            #expect(Self.read(ring, 4) == [expected, expected + 1, expected + 2, expected + 3])
            expected += 4
            ring.write([expected, expected + 1, expected + 2, expected + 3])
        }
    }

    @Test func reprimesAfterFullStall() {
        let ring = Self.make()
        ring.write([1, 2, 3, 4])
        #expect(ring.isPrimed)
        #expect(Self.read(ring, 4) == [1, 2, 3, 4])  // drains exactly, no underrun
        #expect(ring.stats().underruns == 0)
        #expect(Self.read(ring, 2) == [0, 0])        // empty -> underrun + de-prime
        #expect(!ring.isPrimed)
        #expect(ring.stats().underruns == 1)
        ring.write([5, 6, 7, 8])                      // refill past threshold -> re-primed
        #expect(ring.isPrimed)
        #expect(Self.read(ring, 4) == [5, 6, 7, 8])
    }

    @Test func keepsPlayingWhenOnePacketIsFifteenMillisecondsLate() {
        let ring = PCMRingBuffer(channelCount: 1, sampleRate: 1_000)
        let packetSamples = 5
        let initialPackets = (ring.primeThreshold + packetSamples - 1) / packetSamples

        for packet in 0..<initialPackets {
            ring.write(Array(repeating: Float(packet + 1), count: packetSamples))
        }
        #expect(ring.isPrimed)

        _ = Self.read(ring, packetSamples)
        ring.write(Array(repeating: Float(initialPackets + 1), count: packetSamples))
        _ = Self.read(ring, packetSamples)

        // The next 5 ms packet is delayed by 15 ms while the device keeps pulling audio.
        for _ in 0..<3 {
            #expect(Self.read(ring, packetSamples).contains(where: { $0 != 0 }))
        }
    }

    @Test func absorbsRecoveredFecBurstWithoutDiscardingBufferedAudio() {
        let ring = PCMRingBuffer(channelCount: 1, sampleRate: 1_000)
        ring.write(Array(repeating: 1, count: 42))

        // RS recovery can release four 5 ms packets in a single receiver turn.
        for packet in 2...5 {
            ring.write(Array(repeating: Float(packet), count: 5))
        }

        #expect(ring.stats().overruns == 0)
        #expect(ring.stats().droppedSamples == 0)
    }
}
