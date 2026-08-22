import Foundation
import Testing
@testable import AsteriaModel

@Suite("Input bindings + resolver")
struct InputBindingsTests {
    @Test("default ⌘⌥ keyboard chords resolve to their actions")
    func keyboardDefaultsResolve() {
        let k = Keybindings.defaults
        #expect(k.action(forKeyboardModifiers: [.command, .option], scancode: 20) == .endStream)        // ⌘⌥Q
        #expect(k.action(forKeyboardModifiers: [.command, .option], scancode: 22) == .toggleStats)       // ⌘⌥S
        #expect(k.action(forKeyboardModifiers: [.command, .option], scancode: 19) == .toggleMouseMode)   // ⌘⌥P
        #expect(k.action(forKeyboardModifiers: [.command, .option], scancode: 16) == .toggleOverlayMenu) // ⌘⌥M
        #expect(k.action(forKeyboardModifiers: [.command, .option, .shift], scancode: 16) == .toggleMute) // ⌘⌥⇧M
    }

    @Test("keyboard match is exact on modifiers and scancode")
    func keyboardExactMatch() {
        let k = Keybindings.defaults
        #expect(k.action(forKeyboardModifiers: [.command], scancode: 20) == nil)                 // missing option
        #expect(k.action(forKeyboardModifiers: [.command, .option, .shift], scancode: 20) == nil) // extra shift
        #expect(k.action(forKeyboardModifiers: [.command, .option], scancode: 0) == nil)          // no key
    }

    @Test("default controller combos resolve regardless of set order")
    func gamepadDefaultsResolve() {
        let k = Keybindings.defaults
        #expect(k.action(forGamepad: [.b, .select, .start]) == .endStream)
        #expect(k.action(forGamepad: [.start, .select, .y]) == .toggleStats)
        #expect(k.action(forGamepad: [.start, .select, .x]) == .toggleMouseMode)
        #expect(k.action(forGamepad: [.start, .select, .dpadUp]) == .toggleOverlayMenu)
        #expect(k.action(forGamepad: [.start, .select, .dpadDown]) == .toggleMute)
    }

    @Test("controller match is exact on the full button set")
    func gamepadExactMatch() {
        let k = Keybindings.defaults
        #expect(k.action(forGamepad: [.start, .select]) == nil)              // subset
        #expect(k.action(forGamepad: [.start, .select, .b, .a]) == nil)      // superset
        #expect(k.action(forGamepad: []) == nil)
    }

    @Test("conflict detection finds the other action sharing a chord")
    func conflicts() {
        let k = Keybindings.defaults
        let statsChord = KeyChord(modifiers: [.command, .option], scancode: 22, keyLabel: "S")
        #expect(k.keyboardConflicts(statsChord, excluding: .endStream) == [.toggleStats])
        #expect(k.keyboardConflicts(statsChord, excluding: .toggleStats) == [])
        let endPad = GamepadChord([.start, .select, .b])
        #expect(k.gamepadConflicts(endPad, excluding: .toggleStats) == [.endStream])
    }

    @Test("set binds and clears, nil/empty removes the entry")
    func setAndClear() {
        var k = Keybindings.defaults
        let chord = KeyChord(modifiers: [.control], scancode: 8, keyLabel: "E")
        k.setKeyboard(chord, for: .toggleMouseMode)
        #expect(k.action(forKeyboardModifiers: [.control], scancode: 8) == .toggleMouseMode)
        k.setKeyboard(.none, for: .toggleMouseMode)
        #expect(k.action(forKeyboardModifiers: [.control], scancode: 8) == nil)
        k.setGamepad(nil, for: .endStream)
        #expect(k.action(forGamepad: [.start, .select, .b]) == nil)
    }

    @Test("fillingMissingDefaults fills absent actions from defaults and keeps persisted chords")
    func fillingMissingDefaults() {
        let keyboard: [StreamAction: KeyChord] = [
            .toggleStats: KeyChord(modifiers: [.control], scancode: 8, keyLabel: "E"),
        ]
        let gamepad: [StreamAction: GamepadChord] = [:]
        let k = Keybindings(keyboard: keyboard, gamepad: gamepad).fillingMissingDefaults()
        // Persisted chord wins.
        #expect(k.keyboard[.toggleStats] == KeyChord(modifiers: [.control], scancode: 8, keyLabel: "E"))
        #expect(k.keyboard[.toggleMute] == Keybindings.defaults.keyboard[.toggleMute])
        #expect(k.keyboard[.endStream] == Keybindings.defaults.keyboard[.endStream])
        #expect(k.gamepad[.toggleMute] == Keybindings.defaults.gamepad[.toggleMute])
        #expect(k.gamepad[.endStream] == Keybindings.defaults.gamepad[.endStream])
    }

    @Test("modifier glyphs render in macOS menu order")
    func glyphOrder() {
        #expect(ChordModifiers([.command, .option]).glyphs == "⌥⌘")
        #expect(ChordModifiers([.control, .option, .shift, .command]).glyphs == "⌃⌥⇧⌘")
        #expect(KeyChord(modifiers: [.command, .option], scancode: 20, keyLabel: "Q").displayString == "⌥⌘Q")
        #expect(KeyChord.none.displayString == "—")
    }

    @Test("gamepad display string is order-stable")
    func gamepadDisplay() {
        #expect(GamepadChord([.b, .select, .start]).displayString == "Start + Select + B")
        #expect(GamepadChord.none.displayString == "—")
    }

    @Test("keybindings round-trip through JSON with object-keyed actions")
    func codableRoundTrip() throws {
        let prefs = InputPreferences.defaults
        let data = try JSONEncoder().encode(prefs)
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("\"endStream\""))
        let decoded = try JSONDecoder().decode(InputPreferences.self, from: data)
        #expect(decoded == prefs)
    }

    @Test("PlayStation controllers emulate a DualShock 4 by default")
    func playStationEmulationDefaultsToDualShock4() throws {
        let prefs = InputPreferences.defaults
        #expect(prefs.playStationEmulation == .playStation4)

        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(prefs))
        var legacy = object as! [String: Any]
        legacy["playStationEmulation"] = nil
        let data = try JSONSerialization.data(withJSONObject: legacy)
        let decoded = try JSONDecoder().decode(InputPreferences.self, from: data)
        #expect(decoded.playStationEmulation == .playStation4)
    }

    @Test("PlayStation LED color persists and defaults to blue")
    func playStationLEDColorPersists() throws {
        let color = PlayStationLEDColor(red: 12, green: 34, blue: 56, opacity: 128)
        let prefs = InputPreferences(playStationLEDColor: color)
        let data = try JSONEncoder().encode(prefs)
        let decoded = try JSONDecoder().decode(InputPreferences.self, from: data)
        #expect(decoded.playStationLEDColor == color)
        #expect(decoded.playStationLEDColor.brightness == Float(128) / 255)

        var legacy = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        legacy["playStationLEDColor"] = nil
        let legacyData = try JSONSerialization.data(withJSONObject: legacy)
        let legacyPrefs = try JSONDecoder().decode(InputPreferences.self, from: legacyData)
        #expect(legacyPrefs.playStationLEDColor == .blue)

        let colorData = try JSONEncoder().encode(color)
        var legacyColor = try JSONSerialization.jsonObject(with: colorData) as! [String: Any]
        legacyColor["opacity"] = nil
        let legacyColorData = try JSONSerialization.data(withJSONObject: legacyColor)
        let decodedLegacyColor = try JSONDecoder().decode(
            PlayStationLEDColor.self,
            from: legacyColorData
        )
        #expect(decodedLegacyColor.opacity == 255)
    }

    @Test("controller battery percentage display preference persists and defaults to off")
    func controllerBatteryPercentageDisplayPersists() throws {
        let prefs = InputPreferences(showControllerBatteryPercentage: true)
        let data = try JSONEncoder().encode(prefs)
        let decoded = try JSONDecoder().decode(InputPreferences.self, from: data)
        #expect(decoded.showControllerBatteryPercentage)

        var legacy = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        legacy["showControllerBatteryPercentage"] = nil
        let legacyData = try JSONSerialization.data(withJSONObject: legacy)
        let legacyPrefs = try JSONDecoder().decode(InputPreferences.self, from: legacyData)
        #expect(!legacyPrefs.showControllerBatteryPercentage)
    }
}
