/// A plain snapshot of a gamepad's buttons and axes, decoupled from `GCExtendedGamepad` (which can't be
/// constructed in tests). The GameController layer fills this from a profile, then converts it to a
/// wire-domain `ControllerSnapshot` via the pure initializer below.
public struct GamepadReading: Sendable, Equatable {
    public var a = false, b = false, x = false, y = false
    public var dpadUp = false, dpadDown = false, dpadLeft = false, dpadRight = false
    public var leftShoulder = false, rightShoulder = false
    public var menu = false        // Start → play
    public var options = false     // Select → back
    public var home = false        // Guide → special
    public var leftThumbstickButton = false, rightThumbstickButton = false
    public var paddle1 = false, paddle2 = false, paddle3 = false, paddle4 = false
    public var share = false       // → misc
    public var touchpad = false    // Sony touchpad click
    public var leftTrigger: Float = 0, rightTrigger: Float = 0
    public var leftStickX: Float = 0, leftStickY: Float = 0
    public var rightStickX: Float = 0, rightStickY: Float = 0

    public init() {}
}

public extension ControllerSnapshot {
    /// Convert GamepadReading to host integer domain: buttons → flags, triggers 0–255, sticks −32768–32767 (no Y inversion).
    init(reading: GamepadReading, index: UInt8, activeMask: UInt16, swapFaceButtons: Bool = false) {
        var a = reading.a, b = reading.b, x = reading.x, y = reading.y
        if swapFaceButtons { swap(&a, &b); swap(&x, &y) }

        var flags: UInt32 = 0
        if a { flags |= GamepadButton.a }
        if b { flags |= GamepadButton.b }
        if x { flags |= GamepadButton.x }
        if y { flags |= GamepadButton.y }
        if reading.dpadUp { flags |= GamepadButton.up }
        if reading.dpadDown { flags |= GamepadButton.down }
        if reading.dpadLeft { flags |= GamepadButton.left }
        if reading.dpadRight { flags |= GamepadButton.right }
        if reading.leftShoulder { flags |= GamepadButton.leftButton }
        if reading.rightShoulder { flags |= GamepadButton.rightButton }
        if reading.menu { flags |= GamepadButton.play }
        if reading.options { flags |= GamepadButton.back }
        if reading.home { flags |= GamepadButton.special }
        if reading.leftThumbstickButton { flags |= GamepadButton.leftStick }
        if reading.rightThumbstickButton { flags |= GamepadButton.rightStick }
        if reading.paddle1 { flags |= GamepadButton.paddle1 }
        if reading.paddle2 { flags |= GamepadButton.paddle2 }
        if reading.paddle3 { flags |= GamepadButton.paddle3 }
        if reading.paddle4 { flags |= GamepadButton.paddle4 }
        if reading.share { flags |= GamepadButton.misc }
        if reading.touchpad { flags |= GamepadButton.touchpad }

        self.init(index: index, activeMask: activeMask, buttonFlags: flags,
                  leftTrigger: Self.toByte(reading.leftTrigger),
                  rightTrigger: Self.toByte(reading.rightTrigger),
                  leftStickX: Self.toAxis(reading.leftStickX),
                  leftStickY: Self.toAxis(reading.leftStickY),
                  rightStickX: Self.toAxis(reading.rightStickX),
                  rightStickY: Self.toAxis(reading.rightStickY))
    }

    /// Truncate toward zero, matching native casts.
    private static func toByte(_ v: Float) -> UInt8 { UInt8(max(0, min(1, v)) * 255) }
    private static func toAxis(_ v: Float) -> Int16 { Int16(max(-1, min(1, v)) * 32767) }
}
