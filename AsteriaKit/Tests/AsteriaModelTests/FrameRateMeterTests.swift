import Foundation
import Testing
@testable import AsteriaModel

@Suite("Frame rate meter (time-normalized FPS)")
struct FrameRateMeterTests {
    @Test func firstSampleHasNoRate() {
        var meter = FrameRateMeter()
        #expect(meter.sample(frames: 0, at: 0) == nil)
    }

    @Test func normalCadenceReadsStreamFps() {
        var meter = FrameRateMeter()
        _ = meter.sample(frames: 0, at: 0)
        #expect(meter.sample(frames: 30, at: 1_000_000_000) == 30)   // 30 frames in 1 s
    }

    @Test func longSnapshotGapNormalizesInsteadOfSpiking() {
        var meter = FrameRateMeter()
        _ = meter.sample(frames: 100, at: 0)
        let rate = meter.sample(frames: 100 + 7_823, at: 260_000_000_000)   // 260 s gap
        #expect(rate == 7_823.0 / 260.0)
        #expect(rate! < 100)
        #expect(Int(rate!.rounded()) == 30)   // what the controller renders
    }

    @Test func counterResetRebasingAndHolds() {
        var meter = FrameRateMeter()
        _ = meter.sample(frames: 100, at: 0)
        #expect(meter.sample(frames: 130, at: 1_000_000_000) == 30)
        // A fresh presentation restarts the counter low; the caller should hold its previous fps.
        #expect(meter.sample(frames: 5, at: 2_000_000_000) == nil)
        // Next interval is measured from the rebased baseline.
        #expect(meter.sample(frames: 35, at: 3_000_000_000) == 30)
    }

    @Test func equalTimestampHolds() {
        var meter = FrameRateMeter()
        _ = meter.sample(frames: 100, at: 0)
        #expect(meter.sample(frames: 130, at: 1_000_000_000) == 30)
        #expect(meter.sample(frames: 160, at: 1_000_000_000) == nil)   // dt == 0, hold previous
        #expect(meter.sample(frames: 190, at: 2_000_000_000) == 30)   // rebased
    }

    @Test func backwardTimestampHolds() {
        var meter = FrameRateMeter()
        _ = meter.sample(frames: 100, at: 5_000_000_000)
        #expect(meter.sample(frames: 130, at: 6_000_000_000) == 30)
        #expect(meter.sample(frames: 160, at: 4_000_000_000) == nil)   // clock regression, hold
        #expect(meter.sample(frames: 190, at: 5_000_000_000) == 30)   // rebased
    }

    @Test func zeroFrameDeltaOverElapsedReturnsZero() {
        var meter = FrameRateMeter()
        _ = meter.sample(frames: 100, at: 0)
        #expect(meter.sample(frames: 100, at: 2_000_000_000) == 0)     // a real stall still shows 0
    }

    @Test func resetClearsState() {
        var meter = FrameRateMeter()
        _ = meter.sample(frames: 100, at: 0)
        #expect(meter.sample(frames: 130, at: 1_000_000_000) == 30)
        meter.reset()
        #expect(meter.sample(frames: 130, at: 1_000_000_000) == nil)   // first sample again
        #expect(meter.sample(frames: 160, at: 2_000_000_000) == 30)   // clean rebase
    }
}
