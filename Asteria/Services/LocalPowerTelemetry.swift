import Foundation
@preconcurrency import Darwin
@preconcurrency import IOKit
@preconcurrency import IOKit.ps
import AsteriaModel

/// Reads local Mac battery state and app-attributed power without extra permission.
/// Battery values use IOPowerSources and live registry telemetry.
/// The IOKit queries can block, so sampling runs off the main actor; the caller owns one instance per polling loop.
struct LocalPowerTelemetry: Sendable {
    private var applicationPowerMeter = ApplicationPowerMeter()

    mutating func sample(at time: Double) -> LaptopStats {
        let registry = registryProperties()
        let description = powerSourceSnapshot()

        let registryHasBattery = boolValue(registry?["BatteryInstalled"]) == true
        let present = boolValue(description?[kIOPSIsPresentKey]) == true
        let hasBattery = present || registryHasBattery
        let currentCapacity = integerValue(description?[kIOPSCurrentCapacityKey])
            ?? integerValue(registry?["CurrentCapacity"])
        let batteryPercent = hasBattery ? currentCapacity.map { max(0, min(100, $0)) } : nil

        let isCharging = boolValue(description?[kIOPSIsChargingKey]) == true
        let isCharged = boolValue(description?[kIOPSIsChargedKey]) == true
            || batteryPercent == 100
        let batteryState: LaptopBatteryState? = hasBattery
            ? state(isCharged: isCharged, isCharging: isCharging)
            : nil

        let timeRemainingMinutes: Int?
        if hasBattery, batteryState == .discharging {
            let fallbackMinutes = fallbackTimeRemainingMinutes(registry: registry,
                                                                description: description)
            timeRemainingMinutes = LaptopTimeEstimate.minutes(
                systemEstimateSeconds: IOPSGetTimeRemainingEstimate(),
                fallbackMinutes: fallbackMinutes
            )
        } else {
            timeRemainingMinutes = nil
        }

        return LaptopStats(
            hasBattery: hasBattery,
            batteryPercent: batteryPercent,
            batteryState: batteryState,
            timeRemainingMinutes: timeRemainingMinutes,
            appPowerWatts: applicationPowerMeter.sample(
                energyNanajoules: processEnergyNanajoules(), at: time)
        )
    }

    private func powerSourceSnapshot() -> [String: Any]? {
        guard let rawBlob = IOPSCopyPowerSourcesInfo(),
              let rawList = IOPSCopyPowerSourcesList(rawBlob.takeUnretainedValue()) else {
            return nil
        }

        let blob = rawBlob.takeRetainedValue()
        let handles = rawList.takeRetainedValue() as NSArray
        var descriptions: [[String: Any]] = []
        for handle in handles {
            guard let description = IOPSGetPowerSourceDescription(blob, handle as CFTypeRef)?
                .takeUnretainedValue() as? [String: Any] else { continue }
            descriptions.append(description)
        }

        let internalBattery = descriptions.first { description in
            Self.string(description[kIOPSTypeKey]) == kIOPSInternalBatteryType
                || Self.string(description[kIOPSTransportTypeKey]) == kIOPSInternalType
        }
        return internalBattery
    }

    private func registryProperties() -> [String: Any]? {
        guard let matching = IOServiceMatching("AppleSmartBattery") else { return nil }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }

        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties,
                                                 kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let properties else { return nil }
        return properties.takeRetainedValue() as? [String: Any]
    }

    private func state(isCharged: Bool, isCharging: Bool) -> LaptopBatteryState {
        if isCharged { return .full }
        return isCharging ? .charging : .discharging
    }

    private func fallbackTimeRemainingMinutes(registry: [String: Any]?,
                                              description: [String: Any]?) -> Int? {
        let batteryData = registry?["BatteryData"] as? [String: Any]
        let candidates = [
            nonNegativeIntegerValue(description?[kIOPSTimeToEmptyKey]),
            nonNegativeIntegerValue(registry?["TimeRemaining"]),
            nonNegativeIntegerValue(registry?["AvgTimeToEmpty"]),
            nonNegativeIntegerValue(batteryData?["AvgTimeToEmpty"]),
            nonNegativeIntegerValue(batteryData?["TimeToEmpty"])
        ].compactMap { $0 }
        return candidates.first { $0 > 0 } ?? candidates.first { $0 == 0 }
    }

    private func processEnergyNanajoules() -> UInt64? {
        var usage = rusage_info_v6()
        let result = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), Int32(RUSAGE_INFO_V6), $0)
            }
        }
        guard result == 0, usage.ri_energy_nj > 0 else { return nil }
        return usage.ri_energy_nj
    }

    private func integerValue(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber else { return nil }
        return number.intValue
    }

    private func nonNegativeIntegerValue(_ value: Any?) -> Int? {
        guard let value = integerValue(value), value >= 0 else { return nil }
        return value
    }

    private func boolValue(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber else { return value as? Bool }
        return number.boolValue
    }

    private nonisolated static func string(_ value: Any?) -> String? {
        if let value = value as? String { return value }
        if let value = value as? NSString { return value as String }
        return nil
    }
}
