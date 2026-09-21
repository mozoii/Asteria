import Foundation
import UIKit
import AsteriaModel

/// Local battery state for the stats HUD.
///
/// iOS exposes far less than the Mac's IOKit registry: there is no public time-to-empty estimate and
/// no per-process energy counter, so those two lines read "—" rather than showing a guess. Level and
/// charge state come from `UIDevice`, which needs battery monitoring switched on first and reports in
/// 5% steps.
struct LocalPowerTelemetry: Sendable {
    /// `UIDevice` is main-actor state, so the read hops to the main actor. The Mac's IOKit equivalent
    /// stays off it because those calls can block; both are awaited from the same polling loop.
    mutating func sample(at time: Double) async -> LaptopStats {
        await MainActor.run {
            let device = UIDevice.current
            if !device.isBatteryMonitoringEnabled { device.isBatteryMonitoringEnabled = true }
            // A simulator, or the first read after enabling monitoring, reports .unknown and -1.
            guard device.batteryState != .unknown, device.batteryLevel >= 0 else {
                return LaptopStats.unavailable
            }
            return LaptopStats(
                hasBattery: true,
                batteryPercent: Int((device.batteryLevel * 100).rounded()),
                batteryState: Self.mapped(device.batteryState),
                // No public API for either on iOS; the HUD renders both as "—".
                timeRemainingMinutes: nil,
                appPowerWatts: nil)
        }
    }

    private static func mapped(_ state: UIDevice.BatteryState) -> LaptopBatteryState {
        switch state {
        case .charging: return .charging
        case .full: return .full
        default: return .discharging
        }
    }
}
