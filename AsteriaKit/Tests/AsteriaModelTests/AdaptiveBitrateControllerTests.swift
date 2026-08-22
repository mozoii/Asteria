import Testing
@testable import AsteriaModel

@Suite("Adaptive bit-rate controller")
struct AdaptiveBitrateControllerTests {
    private func drive(_ c: inout AdaptiveBitrateController, lossPercent: Double, seconds: Int) {
        for _ in 0..<seconds { _ = c.tick(lossPercent: lossPercent) }
    }

    @Test("Starts at the ceiling and never exceeds it")
    func startsAtCeiling() {
        var c = AdaptiveBitrateController(initialKbps: 20_000, mode: .preferQuality)
        #expect(c.currentKbps == 20_000)
        #expect(c.ceilingKbps == 20_000)
        for _ in 0..<30 { #expect(c.tick(lossPercent: 0) == nil) }
        #expect(c.currentKbps == 20_000)
    }

    @Test("Heavy loss cuts immediately on the same tick")
    func heavyLossCuts() {
        var c = AdaptiveBitrateController(initialKbps: 20_000, mode: .preferQuality)
        let target = c.tick(lossPercent: 10)   // ≥ Prefer Quality heavy (8)
        #expect(target == 16_000)              // 20_000 * 0.80
        #expect(c.currentKbps == 16_000)
    }

    @Test("Mild loss cuts gently")
    func mildLossCuts() {
        var c = AdaptiveBitrateController(initialKbps: 20_000, mode: .preferQuality)
        let target = c.tick(lossPercent: 5)    // ≥ mild (4), < heavy (8)
        #expect(target == 18_400)              // 20_000 * 0.92
    }

    @Test("Sustained loss compounds down but never below the floor")
    func floorHolds() {
        var c = AdaptiveBitrateController(initialKbps: 20_000, mode: .preferQuality)
        let floor = c.floorKbps
        #expect(floor == 12_000)               // 0.60 * 20_000
        drive(&c, lossPercent: 20, seconds: 30)
        #expect(c.currentKbps == floor)
    }

    @Test("Recovers upward after a loss-free stretch, but only up to the ceiling")
    func recovers() {
        var c = AdaptiveBitrateController(initialKbps: 20_000, mode: .preferQuality)
        _ = c.tick(lossPercent: 10)            // cut to 16_000
        #expect(c.currentKbps == 16_000)
        // Prefer Quality probes after 3 loss-free seconds; the first probe after a cut is cautious (1.03).
        #expect(c.tick(lossPercent: 0) == nil) // 1
        #expect(c.tick(lossPercent: 0) == nil) // 2
        let firstProbe = c.tick(lossPercent: 0) // 3 → 16_000 * 1.03
        #expect(firstProbe == 16_480)
        drive(&c, lossPercent: 0, seconds: 300)
        #expect(c.currentKbps == 20_000)
    }

    @Test("Prefer Latency reacts to loss that Prefer Quality tolerates")
    func modeSensitivity() {
        var quality = AdaptiveBitrateController(initialKbps: 30_000, mode: .preferQuality)
        var latency = AdaptiveBitrateController(initialKbps: 30_000, mode: .preferLatency)
        // 2% loss: below Prefer Quality's mild threshold (4), at/above Prefer Latency's (1).
        #expect(quality.tick(lossPercent: 2) == nil)
        #expect(latency.tick(lossPercent: 2) != nil)
        #expect(latency.currentKbps < 30_000)
    }

    @Test("Prefer Latency drops to a lower floor than Prefer Quality")
    func modeFloors() {
        let quality = AdaptiveBitrateController(initialKbps: 30_000, mode: .preferQuality)
        let latency = AdaptiveBitrateController(initialKbps: 30_000, mode: .preferLatency)
        #expect(quality.floorKbps == 18_000)   // 0.60
        #expect(latency.floorKbps == 10_500)   // 0.35
    }

    @Test("The floor never drops below the absolute minimum for tiny streams")
    func absoluteFloor() {
        let c = AdaptiveBitrateController(initialKbps: 5_000, mode: .preferLatency)
        // 0.35 * 5_000 = 1_750, lifted to the 2_000 absolute floor.
        #expect(c.floorKbps == 2_000)
    }

    @Test("Switching mode live re-clamps the current rate into the new band")
    func liveModeChange() {
        var c = AdaptiveBitrateController(initialKbps: 20_000, mode: .preferLatency)
        drive(&c, lossPercent: 20, seconds: 30)  // settle at the Prefer Latency floor (7_000)
        #expect(c.currentKbps == 7_000)
        // Prefer Quality's floor (12_000) is higher, so the switch lifts the current rate and reports it.
        let lifted = c.setMode(.preferQuality)
        #expect(lifted == 12_000)
        #expect(c.currentKbps == 12_000)
    }

    @Test("Switching to the same mode is a no-op")
    func sameModeNoop() {
        var c = AdaptiveBitrateController(initialKbps: 20_000, mode: .preferQuality)
        #expect(c.setMode(.preferQuality) == nil)
    }
}
