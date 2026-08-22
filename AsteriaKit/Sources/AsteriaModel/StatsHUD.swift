import Foundation

/// Turns a monotonic byte counter into a smoothed bitrate (Mbps); resets cleanly when the counter restarts.
public struct RateMeter: Sendable, Equatable {
    private var lastBytes: Int?
    private var lastTime: Double?
    public private(set) var mbps: Double = 0

    public init() {}

    /// Feed the cumulative byte total and a monotonic timestamp (seconds); returns the updated Mbps.
    @discardableResult
    public mutating func sample(totalBytes: Int, at time: Double) -> Double {
        defer { lastBytes = totalBytes; lastTime = time }
        guard let lastBytes, let lastTime else { return mbps }
        if totalBytes < lastBytes { mbps = 0; return mbps }   // counter restarted (new session)
        guard time > lastTime else { return mbps }            // no time elapsed → hold last rate
        mbps = Double(totalBytes - lastBytes) * 8 / (time - lastTime) / 1_000_000
        return mbps
    }
}

/// The power state of the Mac's internal battery.
public enum LaptopBatteryState: Sendable, Equatable {
    case discharging
    case charging
    case full
}

/// One local Mac telemetry snapshot. Battery fields are absent on desktop Macs;
/// app power remains available whenever macOS exposes a live reading.
public struct LaptopStats: Sendable, Equatable {
    public var hasBattery: Bool
    public var batteryPercent: Int?
    public var batteryState: LaptopBatteryState?
    /// macOS's estimate, rounded down to whole minutes; nil means the estimate is unavailable.
    public var timeRemainingMinutes: Int?
    /// Average power attributed to the application during the latest sample window.
    public var appPowerWatts: Double?

    public init(hasBattery: Bool = false, batteryPercent: Int? = nil,
                batteryState: LaptopBatteryState? = nil, timeRemainingMinutes: Int? = nil,
                appPowerWatts: Double? = nil) {
        self.hasBattery = hasBattery
        self.batteryPercent = batteryPercent
        self.batteryState = batteryState
        self.timeRemainingMinutes = timeRemainingMinutes
        self.appPowerWatts = appPowerWatts
    }

    public static let unavailable = LaptopStats()
}

public enum LaptopTimeEstimate {
    public static func minutes(systemEstimateSeconds: Double,
                               fallbackMinutes: Int?) -> Int? {
        if systemEstimateSeconds.isFinite, systemEstimateSeconds > 0 {
            return Int((systemEstimateSeconds / 60).rounded(.down))
        }
        guard let fallbackMinutes, fallbackMinutes >= 0 else { return nil }
        return fallbackMinutes
    }
}

/// Converts cumulative process energy samples into average application power.
public struct ApplicationPowerMeter: Sendable, Equatable {
    private static let nanajoulesPerJoule = 1_000_000_000.0

    private var lastEnergyNanajoules: UInt64?
    private var lastSampleTime: Double?

    public init() {}

    public mutating func reset() {
        self = Self()
    }

    /// Returns watts for the interval since the previous valid process-energy sample.
    @discardableResult
    public mutating func sample(energyNanajoules: UInt64?, at time: Double) -> Double? {
        guard time.isFinite else {
            reset()
            return nil
        }

        if let lastSampleTime, time <= lastSampleTime {
            if time < lastSampleTime { reset() }
            return nil
        }

        guard let energyNanajoules else { return nil }
        let previousEnergy = lastEnergyNanajoules
        let previousTime = lastSampleTime
        lastEnergyNanajoules = energyNanajoules
        lastSampleTime = time

        guard let previousEnergy, let previousTime,
              energyNanajoules >= previousEnergy else { return nil }
        let elapsed = time - previousTime
        let watts = Double(energyNanajoules - previousEnergy)
            / elapsed / Self.nanajoulesPerJoule
        guard watts.isFinite, watts >= 0 else { return nil }
        return watts
    }
}

/// Smooths power samples and detects sustained high usage relative to the Mac's
/// recent workload. The meter resets for each stream.
public struct PowerUsageMeter: Sendable, Equatable {
    public static let smoothingWindowSeconds = 2.0
    public static let baselineWindowSeconds = 5.0 * 60.0
    public static let warmupSeconds = 60.0
    public static let highUsageMultiplier = 1.5
    public static let requiredHighSamples = 3

    private struct TimedValue: Sendable, Equatable {
        let time: Double
        let watts: Double
    }

    private var rawSamples: [TimedValue] = []
    private var smoothedSamples: [TimedValue] = []
    private var startedAt: Double?
    private var lastSampleTime: Double?
    private var consecutiveHighSamples = 0

    public private(set) var smoothedWatts: Double?
    public private(set) var baselineWatts: Double?
    public private(set) var isHighPower = false

    public init() {}

    public mutating func reset() {
        self = Self()
    }

    /// Adds a power sample and returns the two-second display average. Missing or invalid samples
    /// clear the current display and warning without discarding the learned baseline.
    @discardableResult
    public mutating func sample(watts: Double?, at time: Double) -> Double? {
        guard time.isFinite else {
            smoothedWatts = nil
            isHighPower = false
            consecutiveHighSamples = 0
            return nil
        }

        if let lastSampleTime, time < lastSampleTime {
            reset()
        }
        lastSampleTime = time

        guard let watts, watts.isFinite, watts >= 0 else {
            smoothedWatts = nil
            isHighPower = false
            consecutiveHighSamples = 0
            return nil
        }

        startedAt = startedAt ?? time
        rawSamples.append(TimedValue(time: time, watts: watts))
        rawSamples.removeAll { $0.time < time - Self.smoothingWindowSeconds }

        let smoothed = rawSamples.map(\.watts).reduce(0, +) / Double(rawSamples.count)
        smoothedWatts = smoothed
        smoothedSamples.append(TimedValue(time: time, watts: smoothed))
        smoothedSamples.removeAll { $0.time < time - Self.baselineWindowSeconds }
        baselineWatts = Self.median(smoothedSamples.map(\.watts))

        guard let startedAt, time - startedAt >= Self.warmupSeconds,
              let baselineWatts, baselineWatts > 0,
              smoothed > baselineWatts * Self.highUsageMultiplier else {
            consecutiveHighSamples = 0
            isHighPower = false
            return smoothed
        }

        consecutiveHighSamples += 1
        isHighPower = consecutiveHighSamples >= Self.requiredHighSamples
        return smoothed
    }

    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }
}

/// Global preferences for in-stream presentation in the Appearance settings section.
public struct OverlayPreferences: Codable, Equatable, Sendable {
    /// Break out the network round-trip latency component.
    public var showNetworkLatency: Bool
    /// Break out the local input pipeline latency component.
    public var showInputLatency: Bool
    /// Break out the frame decode latency component.
    public var showDecodeLatency: Bool
    /// Show adaptive-bitrate status toasts when macOS notification permission allows them.
    public var showAdaptiveBitrateNotifications: Bool
    /// Show a toast when stream audio is muted or unmuted.
    public var showMuteNotifications: Bool

    public init(showNetworkLatency: Bool = false, showInputLatency: Bool = false,
                showDecodeLatency: Bool = false,
                showAdaptiveBitrateNotifications: Bool = true,
                showMuteNotifications: Bool = true) {
        self.showNetworkLatency = showNetworkLatency
        self.showInputLatency = showInputLatency
        self.showDecodeLatency = showDecodeLatency
        self.showAdaptiveBitrateNotifications = showAdaptiveBitrateNotifications
        self.showMuteNotifications = showMuteNotifications
    }

    // Tolerant decode so preferences written before a field existed load with that field's default.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        showNetworkLatency = try c.decodeIfPresent(Bool.self, forKey: .showNetworkLatency) ?? false
        showInputLatency = try c.decodeIfPresent(Bool.self, forKey: .showInputLatency) ?? false
        showDecodeLatency = try c.decodeIfPresent(Bool.self, forKey: .showDecodeLatency) ?? false
        showAdaptiveBitrateNotifications = try c.decodeIfPresent(
            Bool.self, forKey: .showAdaptiveBitrateNotifications) ?? true
        showMuteNotifications = try c.decodeIfPresent(Bool.self, forKey: .showMuteNotifications) ?? true
    }

    public static let defaults = OverlayPreferences()
}

/// How a HUD value is tinted: `warn` (orange) for a value needing attention, `good` (green) for an
/// enhancement that's engaged, and the two battery-specific severities.
public enum StatEmphasis: Sendable, Equatable {
    case normal, warn, good, lowBattery, criticalBattery
}

/// One labeled HUD metric with the emphasis that drives its tint.
public struct StatLine: Sendable, Equatable, Identifiable {
    public let label: String
    public let value: String
    public let emphasis: StatEmphasis
    public var id: String { label }

    public init(label: String, value: String, emphasis: StatEmphasis = .normal) {
        self.label = label
        self.value = value
        self.emphasis = emphasis
    }
}

/// Formats a live telemetry sample into the in-stream stats HUD lines.
/// `Network` is the ENet control-channel round-trip (network latency only) — distinct from `Decode`.
public struct StatsHUDModel: Sendable, Equatable {
    public var resolution: String
    public var fps: Int
    public var rttMillis: Int
    public var lossPercent: Double
    public var bitrateMbps: Double
    public var decodeMillis: Double
    /// Mean enqueue→flush latency of the local input path (ms) — the "input" term of round-trip latency.
    public var inputMillis: Double
    public var metalFX: Bool
    public var hdr: Bool
    /// Set while the adaptive-bitrate controller is driving the rate; tags the Bitrate line with the mode.
    public var adaptiveMode: AdaptiveMode?
    /// Overlay customization: break out each latency component below the always-shown total.
    public var showNetworkLatency: Bool
    public var showInputLatency: Bool
    public var showDecodeLatency: Bool
    /// Local Mac telemetry; battery rows are conditional on hardware.
    public var laptopStats: LaptopStats = .unavailable
    /// True after three consecutive high-usage samples after warm-up.
    public var powerUsageHigh = false

    public init(resolution: String = "", fps: Int = 0, rttMillis: Int = 0, lossPercent: Double = 0,
                bitrateMbps: Double = 0, decodeMillis: Double = 0, inputMillis: Double = 0,
                metalFX: Bool = false, hdr: Bool = false, adaptiveMode: AdaptiveMode? = nil,
                showNetworkLatency: Bool = false,
                showInputLatency: Bool = false, showDecodeLatency: Bool = false) {
        self.resolution = resolution
        self.fps = fps
        self.rttMillis = rttMillis
        self.lossPercent = lossPercent
        self.bitrateMbps = bitrateMbps
        self.decodeMillis = decodeMillis
        self.inputMillis = inputMillis
        self.metalFX = metalFX
        self.hdr = hdr
        self.adaptiveMode = adaptiveMode
        self.showNetworkLatency = showNetworkLatency
        self.showInputLatency = showInputLatency
        self.showDecodeLatency = showDecodeLatency
    }

    public init(laptopStats: LaptopStats, powerUsageHigh: Bool = false) {
        self.init()
        self.laptopStats = laptopStats
        self.powerUsageHigh = powerUsageHigh
    }

    /// Client-measurable round trip: input pipeline + network RTT + decode. A lower bound (host capture/encode
    /// and display present aren't visible); 0 until the terms are measured.
    public var roundTripMillis: Double { inputMillis + Double(rttMillis) + decodeMillis }

    public var lines: [StatLine] {
        coreLines + latencyLines + enhancementLines + laptopLines
    }

    private var coreLines: [StatLine] {
        var lines: [StatLine] = []
        if !resolution.isEmpty { lines.append(StatLine(label: "Resolution", value: resolution)) }
        lines.append(StatLine(label: "FPS", value: "\(fps)"))
        let shownLoss = (lossPercent * 10).rounded() / 10
        lines.append(StatLine(label: "Loss",
                              value: String(format: "%.1f%%", shownLoss),
                              emphasis: shownLoss > 0 ? .warn : .normal))
        let bitrateLabel = adaptiveMode.map { "Bitrate (\($0.shortName))" } ?? "Bitrate"
        lines.append(StatLine(label: bitrateLabel, value: String(format: "%.1f Mbps", bitrateMbps)))
        return lines
    }

    private var latencyLines: [StatLine] {
        var lines: [StatLine] = []
        if showDecodeLatency {
            lines.append(StatLine(label: "Decode",
                                  value: decodeMillis == 0 ? "—" : String(format: "%.1f ms", decodeMillis),
                                  emphasis: decodeMillis >= 16 ? .warn : .normal))
        }
        if showNetworkLatency {
            lines.append(StatLine(label: "Network",
                                  value: rttMillis == 0 ? "—" : "\(rttMillis) ms",
                                  emphasis: rttMillis >= 100 ? .warn : .normal))
        }
        if showInputLatency {
            lines.append(StatLine(label: "Input",
                                  value: inputMillis == 0 ? "—" : String(format: "%.1f ms", inputMillis),
                                  emphasis: inputMillis >= 16 ? .warn : .normal))
        }
        let latency = roundTripMillis
        lines.append(StatLine(label: "Latency",
                              value: latency == 0 ? "—" : String(format: "%.1f ms", latency),
                              emphasis: latency >= 50 ? .warn : .normal))
        return lines
    }

    private var enhancementLines: [StatLine] {
        var lines: [StatLine] = []
        if metalFX { lines.append(StatLine(label: "MetalFX", value: "On", emphasis: .good)) }
        if hdr { lines.append(StatLine(label: "HDR", value: "On", emphasis: .good)) }
        return lines
    }

    private var laptopLines: [StatLine] {
        let powerValue = laptopStats.appPowerWatts.map { String(format: "%.1f W", $0) } ?? "—"
        let powerEmphasis: StatEmphasis = powerUsageHigh && laptopStats.appPowerWatts != nil
            ? .warn : .normal
        let powerLine = StatLine(label: "App Power", value: powerValue,
                                 emphasis: powerEmphasis)
        var lines = [powerLine]
        guard laptopStats.hasBattery else { return lines }
        lines.append(batteryLine)
        lines.append(timeLine)
        return lines
    }

    private var batteryLine: StatLine {
        let emphasis: StatEmphasis
        switch laptopStats.batteryPercent {
        case let percent? where percent <= 10: emphasis = .criticalBattery
        case let percent? where percent <= 20: emphasis = .lowBattery
        default: emphasis = .normal
        }
        let value = laptopStats.batteryPercent.map { "\($0)%" } ?? "—"
        return StatLine(label: "Battery", value: value, emphasis: emphasis)
    }

    private var timeLine: StatLine {
        let value: String
        switch laptopStats.batteryState {
        case .charging: value = "Charging"
        case .full: value = "Full"
        case .discharging:
            value = Self.formatTimeRemaining(laptopStats.timeRemainingMinutes)
        case nil: value = "—"
        }
        return StatLine(label: "Time left", value: value)
    }

    private static func formatTimeRemaining(_ minutes: Int?) -> String {
        guard let minutes, minutes >= 0 else { return "—" }
        if minutes < 1 { return "<1m" }
        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        if hours > 0 {
            return remainingMinutes == 0 ? "\(hours)h" : "\(hours)h \(remainingMinutes)m"
        }
        return "\(minutes)m"
    }
}
