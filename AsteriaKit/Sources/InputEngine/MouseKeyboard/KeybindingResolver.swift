import GameStreamProtocol
import AsteriaModel

/// Runtime view over `Keybindings`: matches a key press or held controller buttons to a `StreamAction`.
struct KeybindingResolver {
    let keybindings: Keybindings

    init(_ keybindings: Keybindings = .defaults) { self.keybindings = keybindings }

    func keyboardAction(scancode: Int, modifiers: KeyModifiers) -> StreamAction? {
        keybindings.action(forKeyboardModifiers: Self.chordModifiers(modifiers.classes), scancode: scancode)
    }

    func gamepadAction(buttonFlags: UInt32) -> StreamAction? {
        keybindings.action(forGamepad: Self.buttonSet(buttonFlags))
    }

    static func chordModifiers(_ c: ModifierClass) -> ChordModifiers {
        var m: ChordModifiers = []
        if c.contains(.ctrl)  { m.insert(.control) }
        if c.contains(.alt)   { m.insert(.option) }
        if c.contains(.shift) { m.insert(.shift) }
        if c.contains(.gui)   { m.insert(.command) }
        return m
    }

    static func buttonSet(_ flags: UInt32) -> Set<GamepadChordButton> {
        let map: [(UInt32, GamepadChordButton)] = [
            (GamepadButton.play, .start), (GamepadButton.back, .select),
            (GamepadButton.a, .a), (GamepadButton.b, .b), (GamepadButton.x, .x), (GamepadButton.y, .y),
            (GamepadButton.leftButton, .leftShoulder), (GamepadButton.rightButton, .rightShoulder),
            (GamepadButton.leftStick, .leftStick), (GamepadButton.rightStick, .rightStick),
            (GamepadButton.up, .dpadUp), (GamepadButton.down, .dpadDown),
            (GamepadButton.left, .dpadLeft), (GamepadButton.right, .dpadRight),
        ]
        var set: Set<GamepadChordButton> = []
        for (flag, button) in map where flags & flag != 0 { set.insert(button) }
        return set
    }
}
