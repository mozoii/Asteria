import Testing
import GameStreamProtocol
import AsteriaModel
@testable import InputEngine

@Suite("KeybindingResolver bridge")
struct KeybindingResolverTests {
    private let resolver = KeybindingResolver(.defaults)

    @Test("tracked modifiers map to the default keyboard actions")
    func keyboardBridge() {
        let cmdOpt: KeyModifiers = [.lGui, .lAlt]                 // ⌘⌥
        #expect(resolver.keyboardAction(scancode: 20, modifiers: cmdOpt) == .endStream)       // Q
        #expect(resolver.keyboardAction(scancode: 19, modifiers: cmdOpt) == .toggleMouseMode)  // P
        #expect(resolver.keyboardAction(scancode: 20, modifiers: [.lGui]) == nil)              // missing ⌥
    }

    @Test("wire button flags decode to the default controller combos")
    func gamepadBridge() {
        let endStream = GamepadButton.play | GamepadButton.back | GamepadButton.b
        #expect(resolver.gamepadAction(buttonFlags: endStream) == .endStream)
        let stats = GamepadButton.play | GamepadButton.back | GamepadButton.y
        #expect(resolver.gamepadAction(buttonFlags: stats) == .toggleStats)
        #expect(resolver.gamepadAction(buttonFlags: GamepadButton.play | GamepadButton.back) == nil)  // subset
    }

    @Test("an unmappable button (guide) is transparent to combo matching")
    func guideTransparent() {
        let endStreamPlusGuide = GamepadButton.play | GamepadButton.back | GamepadButton.b | GamepadButton.special
        #expect(resolver.gamepadAction(buttonFlags: endStreamPlusGuide) == .endStream)
    }

    @Test("ModifierClass converts to ChordModifiers")
    func modifierConversion() {
        #expect(KeybindingResolver.chordModifiers([.gui, .alt]) == [.command, .option])
        #expect(KeybindingResolver.chordModifiers([.ctrl, .shift]) == [.control, .shift])
    }
}
