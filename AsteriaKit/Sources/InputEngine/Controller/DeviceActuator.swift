/// A haptic locality, decoupled from `GCHapticsLocality` for testable actuator decisions.
enum HapticLocality: Sendable, Hashable {
    case leftHandle, rightHandle, combined, leftTrigger, rightTrigger
}

/// Which DualSense adaptive trigger an effect targets.
enum TriggerSide: Sendable, Equatable {
    case left, right
}

/// Device-actuation seam: drive intensity, LED, or adaptive-trigger effects. The core decides what to drive; the actuator applies it.
protocol DeviceActuator: AnyObject, Sendable {
    func setIntensity(slot: Int, locality: HapticLocality, intensity: Float)
    func setLED(slot: Int, red: UInt8, green: UInt8, blue: UInt8)
    func setAdaptiveTrigger(slot: Int, side: TriggerSide, type: UInt8, effect: [UInt8])
}

/// A controller's battery state in the host integer domain.
struct BatterySample: Sendable, Equatable {
    let state: UInt8
    let percentage: UInt8
}

/// Controller arrival facts: identity, capabilities, battery, and rumble-handle support.
struct GamepadArrival: Sendable, Equatable {
    let index: UInt8
    let type: UInt8
    let supportedButtonFlags: UInt32
    let capabilities: UInt16
    let battery: BatterySample?
    let supportsSplitHandles: Bool
}
