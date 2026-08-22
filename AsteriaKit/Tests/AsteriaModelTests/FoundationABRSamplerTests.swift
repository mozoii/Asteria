import Testing
@testable import AsteriaModel

@Suite("Foundation ABR telemetry sampler")
struct FoundationABRSamplerTests {
    @Test func convertsCumulativeCountersIntoIntervalMetrics() throws {
        var sampler = FoundationABRSampler()
        #expect(sampler.sample(snapshot(at: 10, frames: counters(
            decoded: 100, delivered: 102, lost: 2, dropped: 1), bytes: 1_000_000)) == nil)

        let result = sampler.sample(snapshot(at: 11, frames: counters(
            decoded: 160, delivered: 164, lost: 4, dropped: 3),
            bytes: 3_500_000, rtt: 18))
        let sample = try #require(result)

        #expect(sample.decodeFps == 60)
        #expect(sample.droppedFrames == 2)
        #expect(sample.packetLossPercent == 3.125)
        #expect(sample.rttMillis == 18)
        #expect(sample.currentBitrateKbps == 20_000)
    }

    @Test func counterResetReestablishesBaselineWithoutInvalidMetrics() {
        var sampler = FoundationABRSampler()
        _ = sampler.sample(snapshot(at: 10, frames: counters(
            decoded: 100, delivered: 100, lost: 2, dropped: 1), bytes: 1_000_000))

        #expect(sampler.sample(snapshot(at: 11, frames: counters(
            decoded: 1, delivered: 1, lost: 0, dropped: 0), bytes: 1_000)) == nil)
        #expect(sampler.sample(snapshot(at: 12, frames: counters(
            decoded: 61, delivered: 61, lost: 0, dropped: 0), bytes: 2_501_000)) != nil)
    }

    private func counters(
        decoded: Int, delivered: Int, lost: Int, dropped: Int
    ) -> FoundationABRFrameCounters {
        FoundationABRFrameCounters(
            decoded: decoded, delivered: delivered, networkLost: lost, dropped: dropped)
    }

    private func snapshot(
        at time: Double, frames: FoundationABRFrameCounters, bytes: Int, rtt: Int = 0
    ) -> FoundationABRSnapshot {
        FoundationABRSnapshot(time: time, frames: frames, videoBytes: bytes, rttMillis: rtt)
    }
}
