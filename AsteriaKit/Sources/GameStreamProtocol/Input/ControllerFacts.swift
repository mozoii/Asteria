/// Controller wire facts for the GameStream protocol: button-flag bits, controller types,
/// capability bits, and battery states. Used by both the capture layer (to build snapshots/arrival)
/// and the encoders. Interoperability values — independently implemented in Swift.
public enum GamepadButton {
    public static let a: UInt32 = 0x1000
    public static let b: UInt32 = 0x2000
    public static let x: UInt32 = 0x4000
    public static let y: UInt32 = 0x8000
    public static let up: UInt32 = 0x0001
    public static let down: UInt32 = 0x0002
    public static let left: UInt32 = 0x0004
    public static let right: UInt32 = 0x0008
    public static let leftButton: UInt32 = 0x0100    // LB
    public static let rightButton: UInt32 = 0x0200   // RB
    public static let play: UInt32 = 0x0010          // Start/Menu
    public static let back: UInt32 = 0x0020          // Select/Options
    public static let leftStick: UInt32 = 0x0040     // LS click
    public static let rightStick: UInt32 = 0x0080    // RS click
    public static let special: UInt32 = 0x0400       // Guide/Home
    public static let paddle1: UInt32 = 0x010000
    public static let paddle2: UInt32 = 0x020000
    public static let paddle3: UInt32 = 0x040000
    public static let paddle4: UInt32 = 0x080000
    public static let touchpad: UInt32 = 0x100000    // Sony touchpad click
    public static let misc: UInt32 = 0x200000        // Share/Mic/Capture

    /// The host quit combo (Start + Select + L1 + R1), consumed locally rather than forwarded.
    public static let quitCombo: UInt32 = play | back | leftButton | rightButton
}

public enum ControllerType {
    public static let unknown: UInt8 = 0x00
    public static let xbox: UInt8 = 0x01
    public static let playStation: UInt8 = 0x02
    public static let nintendo: UInt8 = 0x03
}

public enum ControllerCapability {
    public static let analogTriggers: UInt16 = 0x01
    public static let rumble: UInt16 = 0x02
    public static let triggerRumble: UInt16 = 0x04
    public static let touchpad: UInt16 = 0x08
    public static let accelerometer: UInt16 = 0x10
    public static let gyro: UInt16 = 0x20
    public static let batteryState: UInt16 = 0x40
    public static let rgbLed: UInt16 = 0x80
}

public enum BatteryState {
    public static let unknown: UInt8 = 0x00
    public static let notPresent: UInt8 = 0x01
    public static let discharging: UInt8 = 0x02
    public static let charging: UInt8 = 0x03
    public static let notCharging: UInt8 = 0x04
    public static let full: UInt8 = 0x05
    public static let percentageUnknown: UInt8 = 0xFF
}
