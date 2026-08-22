import Foundation
import Testing
@testable import AsteriaModel

@Suite("Stats HUD model + rate meter")
struct StatsHUDTests {
    @Test func firstSampleHasNoRate() {
        var meter = RateMeter()
        #expect(meter.sample(totalBytes: 1_000_000, at: 0) == 0)
    }

    @Test func computesMbpsFromByteDelta() {
        var meter = RateMeter()
        _ = meter.sample(totalBytes: 0, at: 0)
        #expect(meter.sample(totalBytes: 1_000_000, at: 1) == 8)   // 1 MB/s = 8 Mbps
    }

    @Test func counterResetClearsRate() {
        var meter = RateMeter()
        _ = meter.sample(totalBytes: 2_000_000, at: 0)
        _ = meter.sample(totalBytes: 4_000_000, at: 1)
        #expect(meter.mbps == 16)
        #expect(meter.sample(totalBytes: 100, at: 2) == 0)   // new session restarted the counter
    }

    @Test func sameTimestampKeepsLastRate() {
        var meter = RateMeter()
        _ = meter.sample(totalBytes: 0, at: 0)
        _ = meter.sample(totalBytes: 1_000_000, at: 1)
        #expect(meter.sample(totalBytes: 2_000_000, at: 1) == 8)   // dt == 0, hold previous
    }

    /// With no component breakdown enabled, the overlay shows the core stats plus the always-on Latency total.
    @Test func linesInDesignedOrder() {
        let lines = StatsHUDModel(resolution: "1920×1080", metalFX: true, hdr: true).lines
        #expect(lines.map(\.label) ==
                ["Resolution", "FPS", "Loss", "Bitrate", "Latency", "MetalFX", "HDR", "App Power"])
    }

    /// Enabling every breakdown lists each component above the total, in decode → network → input order.
    @Test func componentBreakdownOrder() {
        let lines = StatsHUDModel(showNetworkLatency: true, showInputLatency: true,
                                  showDecodeLatency: true).lines
        #expect(lines.map(\.label) ==
                ["FPS", "Loss", "Bitrate", "Decode", "Network", "Input", "Latency", "App Power"])
    }

    @Test func resolutionLineOmittedWhenUnknown() {
        #expect(StatsHUDModel().lines.first?.label == "FPS")   // no resolution line until the plan is known
    }

    @Test func formatsValues() {
        let m = StatsHUDModel(resolution: "1920×1080", fps: 60, rttMillis: 12, lossPercent: 0,
                              bitrateMbps: 19.6, decodeMillis: 3.2, inputMillis: 1.8, metalFX: true,
                              showNetworkLatency: true, showInputLatency: true, showDecodeLatency: true)
        let v = Dictionary(uniqueKeysWithValues: m.lines.map { ($0.label, $0.value) })
        #expect(v["Resolution"] == "1920×1080")
        #expect(v["FPS"] == "60")
        #expect(v["Network"] == "12 ms")
        #expect(v["Loss"] == "0.0%")
        #expect(v["Bitrate"] == "19.6 Mbps")
        #expect(v["Decode"] == "3.2 ms")
        #expect(v["Input"] == "1.8 ms")
        #expect(v["Latency"] == "17.0 ms")            // 1.8 + 12 + 3.2
        #expect(v["MetalFX"] == "On")
    }

    @Test func bitrateLineTaggedWithAdaptiveMode() {
        #expect(StatsHUDModel(bitrateMbps: 18).lines.contains { $0.label == "Bitrate" })
        let quality = StatsHUDModel(bitrateMbps: 18, adaptiveMode: .preferQuality).lines
        #expect(quality.contains { $0.label == "Bitrate (Quality)" })
        #expect(quality.contains { $0.label == "Bitrate" } == false)
        let latency = StatsHUDModel(bitrateMbps: 18, adaptiveMode: .preferLatency).lines
        #expect(latency.contains { $0.label == "Bitrate (Latency)" })
    }

    @Test func metalFXLineShownOnlyWhenEnabled() {
        #expect(StatsHUDModel(metalFX: false).lines.contains { $0.label == "MetalFX" } == false)
        let on = StatsHUDModel(metalFX: true).lines.first { $0.label == "MetalFX" }
        #expect(on?.value == "On")
        #expect(on?.emphasis == .good)
    }

    @Test func componentsHiddenUntilEnabled() {
        let none = StatsHUDModel(rttMillis: 20, decodeMillis: 4, inputMillis: 2).lines.map(\.label)
        #expect(none.contains("Decode") == false)
        #expect(none.contains("Network") == false)
        #expect(none.contains("Input") == false)
    }

    @Test func unmeasuredComponentsShowDash() {
        let m = StatsHUDModel(rttMillis: 0, decodeMillis: 0, inputMillis: 0,
                              showNetworkLatency: true, showInputLatency: true, showDecodeLatency: true)
        let v = Dictionary(uniqueKeysWithValues: m.lines.map { ($0.label, $0.value) })
        #expect(v["Network"] == "—")
        #expect(v["Decode"] == "—")
        #expect(v["Input"] == "—")
    }

    @Test func subVisibleLossShowsZeroAndDoesNotWarn() {
        // 0.04% rounds to "0.0%" on screen, so the loss line must not paint orange while showing zero.
        let loss = StatsHUDModel(lossPercent: 0.04).lines.first { $0.label == "Loss" }
        #expect(loss?.value == "0.0%")
        #expect(loss?.emphasis == .normal)
    }

    @Test func smallButVisibleLossWarns() {
        let loss = StatsHUDModel(lossPercent: 0.1).lines.first { $0.label == "Loss" }
        #expect(loss?.value == "0.1%")
        #expect(loss?.emphasis == .warn)
    }

    @Test func hdrLineShownOnlyWhenActive() {
        #expect(StatsHUDModel(hdr: false).lines.contains { $0.label == "HDR" } == false)
        let on = StatsHUDModel(resolution: "1920×1080", hdr: true)
        #expect(on.lines.map(\.label) ==
                ["Resolution", "FPS", "Loss", "Bitrate", "Latency", "HDR", "App Power"])
        let hdr = on.lines.first { $0.label == "HDR" }
        #expect(hdr?.value == "On")
        #expect(hdr?.emphasis == .good)
    }

    @Test func warnsOnLossAndSlowComponents() {
        let m = StatsHUDModel(rttMillis: 120, lossPercent: 1.5, decodeMillis: 20,
                              showNetworkLatency: true, showDecodeLatency: true)
        let e = Dictionary(uniqueKeysWithValues: m.lines.map { ($0.label, $0.emphasis) })
        #expect(e["Network"] == .warn)
        #expect(e["Loss"] == .warn)
        #expect(e["Decode"] == .warn)
        #expect(e["FPS"] == .normal)
        #expect(e["Bitrate"] == .normal)
    }

    @Test func healthyValuesDoNotWarn() {
        let m = StatsHUDModel(fps: 60, rttMillis: 8, lossPercent: 0, bitrateMbps: 20, decodeMillis: 4)
        #expect(m.lines.allSatisfy { $0.emphasis == .normal })   // Latency total 12 ms < 50 ms
    }

    @Test func latencySumsInputNetworkAndDecode() {
        let m = StatsHUDModel(rttMillis: 20, decodeMillis: 4, inputMillis: 2.5)
        let line = m.lines.first { $0.label == "Latency" }
        #expect(m.roundTripMillis == 26.5)          // 2.5 input + 20 network + 4 decode
        #expect(line?.value == "26.5 ms")
        #expect(line?.emphasis == .normal)
    }

    @Test func latencyDashWhenUnmeasured() {
        let line = StatsHUDModel().lines.first { $0.label == "Latency" }
        #expect(line?.value == "—")
    }

    @Test func latencyWarnsAtFiftyMillis() {
        let below = StatsHUDModel(rttMillis: 45, decodeMillis: 4).lines.first { $0.label == "Latency" }
        #expect(below?.emphasis == .normal)         // 49 ms < 50 ms
        let at = StatsHUDModel(rttMillis: 46, decodeMillis: 4).lines.first { $0.label == "Latency" }
        #expect(at?.emphasis == .warn)              // 50 ms ≥ 50 ms threshold
    }

    @Test func laptopRowsAreSeparateAndOrdered() {
        let stats = LaptopStats(hasBattery: true, batteryPercent: 82, batteryState: .discharging,
                                timeRemainingMinutes: 134, appPowerWatts: 18.4)
        let lines = StatsHUDModel(laptopStats: stats).lines
        #expect(lines.suffix(3).map(\.label) == ["App Power", "Battery", "Time left"])
        #expect(lines.last?.value == "2h 14m")
        #expect(lines[lines.count - 3].value == "18.4 W")
        #expect(lines[lines.count - 2].value == "82%")
    }

    @Test func desktopOmitsBatteryRowsButKeepsPowerUsage() {
        let lines = StatsHUDModel(laptopStats: LaptopStats(appPowerWatts: 31.2)).lines
        #expect(lines.map(\.label).contains("App Power"))
        #expect(lines.map(\.label).contains("Battery") == false)
        #expect(lines.map(\.label).contains("Time left") == false)
    }

    @Test func unavailableLaptopValuesStayVisibleAsDashes() {
        let lines = StatsHUDModel(laptopStats: LaptopStats(hasBattery: true)).lines
        let values = Dictionary(uniqueKeysWithValues: lines.suffix(3).map { ($0.label, $0.value) })
        #expect(values["App Power"] == "—")
        #expect(values["Battery"] == "—")
        #expect(values["Time left"] == "—")
    }

    @Test func chargingAndFullReplaceTheTimeCountdown() {
        let charging = StatsHUDModel(laptopStats: LaptopStats(hasBattery: true, batteryPercent: 80,
                                                              batteryState: .charging,
                                                              timeRemainingMinutes: nil)).lines
        #expect(charging.first { $0.label == "Time left" }?.value == "Charging")

        let full = StatsHUDModel(laptopStats: LaptopStats(hasBattery: true, batteryPercent: 100,
                                                          batteryState: .full)).lines
        #expect(full.first { $0.label == "Time left" }?.value == "Full")
    }

    @Test func timeRemainingUsesWholeHumanReadableMinutes() {
        let underHour = StatsHUDModel(laptopStats: LaptopStats(hasBattery: true,
                                                               batteryState: .discharging,
                                                               timeRemainingMinutes: 47)).lines
        #expect(underHour.first { $0.label == "Time left" }?.value == "47m")

        let underMinute = StatsHUDModel(laptopStats: LaptopStats(hasBattery: true,
                                                                 batteryState: .discharging,
                                                                 timeRemainingMinutes: 0)).lines
        #expect(underMinute.first { $0.label == "Time left" }?.value == "<1m")
    }

    @Test func batteryThresholdsAreInclusiveAndRedTakesPrecedence() {
        let yellowStats = LaptopStats(hasBattery: true, batteryPercent: 20)
        let yellow = StatsHUDModel(laptopStats: yellowStats).lines
            .first { $0.label == "Battery" }
        #expect(yellow?.emphasis == .lowBattery)

        let redStats = LaptopStats(hasBattery: true, batteryPercent: 10)
        let red = StatsHUDModel(laptopStats: redStats).lines
            .first { $0.label == "Battery" }
        #expect(red?.emphasis == .criticalBattery)

        let healthyStats = LaptopStats(hasBattery: true, batteryPercent: 21)
        let healthy = StatsHUDModel(laptopStats: healthyStats).lines
            .first { $0.label == "Battery" }
        #expect(healthy?.emphasis == .normal)
    }

    @Test func batterySeverityDoesNotTintTimeRemaining() {
        let lines = StatsHUDModel(laptopStats: LaptopStats(hasBattery: true,
                                                           batteryPercent: 10,
                                                           batteryState: .discharging,
                                                           timeRemainingMinutes: 8)).lines
        #expect(lines.first { $0.label == "Battery" }?.emphasis == .criticalBattery)
        #expect(lines.first { $0.label == "Time left" }?.emphasis == .normal)
    }

    @Test func highPowerUsageUsesOrangeWarning() {
        let stats = LaptopStats(appPowerWatts: 42)
        let line = StatsHUDModel(laptopStats: stats, powerUsageHigh: true).lines
            .first { $0.label == "App Power" }
        #expect(line?.emphasis == .warn)
    }
}

@Suite("Application power meter")
struct ApplicationPowerMeterTests {
    @Test func firstSampleHasNoPower() {
        var meter = ApplicationPowerMeter()
        #expect(meter.sample(energyNanajoules: 1_000_000_000, at: 0) == nil)
    }

    @Test func convertsEnergyDeltaToAverageWatts() {
        var meter = ApplicationPowerMeter()
        _ = meter.sample(energyNanajoules: 1_000_000_000, at: 0)
        #expect(meter.sample(energyNanajoules: 6_000_000_000, at: 1) == 5)
    }

    @Test func counterResetStartsANewInterval() {
        var meter = ApplicationPowerMeter()
        _ = meter.sample(energyNanajoules: 6_000_000_000, at: 0)
        #expect(meter.sample(energyNanajoules: 1_000_000_000, at: 1) == nil)
        #expect(meter.sample(energyNanajoules: 3_000_000_000, at: 2) == 2)
    }
}

@Suite("Adaptive power usage meter")
struct PowerUsageMeterTests {
    @Test func smoothsDisplayAndWaitsForWarmupAndConsecutiveSamples() {
        var meter = PowerUsageMeter()
        for second in 0...60 {
            _ = meter.sample(watts: 20, at: Double(second))
        }
        #expect(meter.baselineWatts == 20)
        #expect(meter.isHighPower == false)

        _ = meter.sample(watts: 40, at: 61)
        _ = meter.sample(watts: 40, at: 62)
        _ = meter.sample(watts: 40, at: 63)
        #expect(meter.smoothedWatts == 40)   // display settles promptly after the step
        #expect(meter.isHighPower == false) // only two smoothed samples exceed the threshold
        _ = meter.sample(watts: 40, at: 64)
        #expect(meter.isHighPower)
        _ = meter.sample(watts: 40, at: 65)
        _ = meter.sample(watts: 40, at: 66)
        _ = meter.sample(watts: 40, at: 67)
        #expect(meter.smoothedWatts == 40)
        #expect(meter.isHighPower)
    }

    @Test func missingSampleClearsDisplayAndWarningWithoutThrowingAwayBaseline() {
        var meter = PowerUsageMeter()
        for second in 0...60 { _ = meter.sample(watts: 20, at: Double(second)) }
        for second in 61...67 { _ = meter.sample(watts: 40, at: Double(second)) }
        #expect(meter.isHighPower)

        #expect(meter.sample(watts: nil, at: 68) == nil)
        #expect(meter.smoothedWatts == nil)
        #expect(meter.isHighPower == false)
        #expect(meter.baselineWatts != nil)
    }

    @Test func usesRegistryTimeWhenSystemEstimateIsUnavailable() {
        #expect(LaptopTimeEstimate.minutes(systemEstimateSeconds: -2,
                                            fallbackMinutes: 174) == 174)
        #expect(LaptopTimeEstimate.minutes(systemEstimateSeconds: 174 * 60,
                                            fallbackMinutes: 10) == 174)
        #expect(LaptopTimeEstimate.minutes(systemEstimateSeconds: -1,
                                            fallbackMinutes: -1) == nil)
    }
}

@Suite("Overlay preferences")
struct OverlayPreferencesTests {
    @Test func defaultsHideAllComponents() {
        #expect(OverlayPreferences.defaults.showNetworkLatency == false)
        #expect(OverlayPreferences.defaults.showInputLatency == false)
        #expect(OverlayPreferences.defaults.showDecodeLatency == false)
        #expect(OverlayPreferences.defaults.showAdaptiveBitrateNotifications == true)
        #expect(OverlayPreferences.defaults.showMuteNotifications == true)
    }

    @Test func decodesMissingFieldsToDefault() throws {
        let data = Data("{}".utf8)   // written before the fields existed
        let prefs = try JSONDecoder().decode(OverlayPreferences.self, from: data)
        #expect(prefs == .defaults)
    }

    @Test func roundTripsThroughCodable() throws {
        let original = OverlayPreferences(showNetworkLatency: true, showInputLatency: false,
                                          showDecodeLatency: true)
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(OverlayPreferences.self, from: data) == original)
    }
}
