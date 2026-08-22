import Foundation

/// In-stream actions a local hotkey can trigger; consumed by the app and never forwarded to the host.
public enum StreamAction: String, Codable, CaseIterable, Sendable, Identifiable {
    case toggleOverlayMenu
    case endStream
    case toggleStats
    case toggleInputCapture
    case toggleMouseMode
    case toggleFullscreen
    case toggleMute

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .toggleOverlayMenu: return "Open overlay menu"
        case .endStream: return "End stream"
        case .toggleStats: return "Toggle stats overlay"
        case .toggleInputCapture: return "Grab / release input"
        case .toggleMouseMode: return "Switch mouse mode"
        case .toggleFullscreen: return "Toggle full screen"
        case .toggleMute: return "Mute / unmute audio"
        }
    }

    public var detail: String {
        switch self {
        case .toggleOverlayMenu: return "Bring up the in-stream menu (resume, end, quit, stats)."
        case .endStream: return "Disconnect and return to the library."
        case .toggleStats: return "Show FPS, latency, loss, and bitrate."
        case .toggleInputCapture: return "Release the pointer back to macOS, or grab it again."
        case .toggleMouseMode: return "Flip between Game and Desktop pointer modes mid-stream."
        case .toggleFullscreen: return "Enter or leave full-screen play."
        case .toggleMute: return "Silence the stream audio, or bring it back."
        }
    }
}

/// Directional navigation for the in-stream overlay menu, surfaced from keyboard arrows and the controller d-pad.
public enum MenuNav: String, Sendable, Equatable {
    case up, down, select, back
}

/// Two explicit pointer modes; default Game. Desktop drives the absolute (1:1) route.
public enum MouseMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case game
    case desktop

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .game: return "Game"
        case .desktop: return "Desktop"
        }
    }

    public var detail: String {
        switch self {
        case .game: return "Best for fast, precise input, like competitive first-person shooters and racing games."
        case .desktop: return "Optimizes the mouse for general use, best for browsing and remote desktop work."
        }
    }

    public var usesAbsolutePointer: Bool { self == .desktop }
}

/// The virtual controller profile reported for connected DualShock and DualSense controllers.
public enum PlayStationControllerEmulation: String, Codable, CaseIterable, Sendable, Identifiable {
    case xbox
    case playStation4

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .xbox: return "Xbox"
        case .playStation4: return "PlayStation"
        }
    }
}

/// The LED color and brightness applied to connected DualShock and DualSense controllers.
public struct PlayStationLEDColor: Codable, Equatable, Sendable {
    public let red: UInt8
    public let green: UInt8
    public let blue: UInt8
    public let opacity: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8, opacity: UInt8 = 255) {
        self.red = red
        self.green = green
        self.blue = blue
        self.opacity = opacity
    }

    public static let blue = PlayStationLEDColor(red: 0, green: 0, blue: 255)

    public var brightness: Float { Float(opacity) / 255 }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        red = try container.decode(UInt8.self, forKey: .red)
        green = try container.decode(UInt8.self, forKey: .green)
        blue = try container.decode(UInt8.self, forKey: .blue)
        opacity = try container.decodeIfPresent(UInt8.self, forKey: .opacity) ?? 255
    }
}

/// Side-agnostic keyboard modifiers for a local chord (`⌘` defaults keep chords off the host's key space).
public struct ChordModifiers: OptionSet, Codable, Equatable, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let control = ChordModifiers(rawValue: 1 << 0)
    public static let option  = ChordModifiers(rawValue: 1 << 1)
    public static let shift   = ChordModifiers(rawValue: 1 << 2)
    public static let command = ChordModifiers(rawValue: 1 << 3)

    /// Glyphs in macOS menu order (⌃⌥⇧⌘).
    public var glyphs: String {
        var s = ""
        if contains(.control) { s += "⌃" }
        if contains(.option)  { s += "⌥" }
        if contains(.shift)   { s += "⇧" }
        if contains(.command) { s += "⌘" }
        return s
    }
}

/// A keyboard hotkey: modifiers plus the non-modifier key, identified by USB-HID scancode (`== GCKeyCode.rawValue`).
public struct KeyChord: Codable, Equatable, Sendable, Hashable {
    public var modifiers: ChordModifiers
    public var scancode: Int
    /// Display label captured when the chord was bound (e.g. "Q", "F5").
    public var keyLabel: String

    public init(modifiers: ChordModifiers, scancode: Int, keyLabel: String) {
        self.modifiers = modifiers
        self.scancode = scancode
        self.keyLabel = keyLabel
    }

    public static let none = KeyChord(modifiers: [], scancode: 0, keyLabel: "")
    public var isEmpty: Bool { scancode == 0 }
    public var displayString: String { isEmpty ? "—" : modifiers.glyphs + keyLabel }
}

/// Buttons usable in a controller combo; abstract here, mapped to wire flags by the engine.
public enum GamepadChordButton: String, Codable, CaseIterable, Sendable, Hashable, Identifiable {
    case start, select, a, b, x, y
    case leftShoulder, rightShoulder, leftStick, rightStick
    case dpadUp, dpadDown, dpadLeft, dpadRight

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .start: return "Start"
        case .select: return "Select"
        case .a: return "A"
        case .b: return "B"
        case .x: return "X"
        case .y: return "Y"
        case .leftShoulder: return "LB"
        case .rightShoulder: return "RB"
        case .leftStick: return "LS"
        case .rightStick: return "RS"
        case .dpadUp: return "D-Up"
        case .dpadDown: return "D-Down"
        case .dpadLeft: return "D-Left"
        case .dpadRight: return "D-Right"
        }
    }

    /// Stable order for display strings, independent of `Set` iteration order.
    public var sortOrder: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}

/// A controller combo: the full set of buttons that must be held together.
public struct GamepadChord: Codable, Equatable, Sendable, Hashable {
    public var buttons: Set<GamepadChordButton>
    public init(_ buttons: Set<GamepadChordButton>) { self.buttons = buttons }

    public static let none = GamepadChord([])
    public var isEmpty: Bool { buttons.isEmpty }
    public var displayString: String {
        isEmpty ? "—" : buttons.sorted { $0.sortOrder < $1.sortOrder }.map(\.displayName).joined(separator: " + ")
    }
}

/// Per-action rebindable hotkeys (keyboard chord and/or controller combo). Missing entry = unbound.
public struct Keybindings: Codable, Equatable, Sendable {
    public var keyboard: [StreamAction: KeyChord]
    public var gamepad: [StreamAction: GamepadChord]

    public init(keyboard: [StreamAction: KeyChord] = [:], gamepad: [StreamAction: GamepadChord] = [:]) {
        self.keyboard = keyboard
        self.gamepad = gamepad
    }

    /// USB-HID scancodes for the default chord keys.
    private enum SC { static let q = 20, s = 22, g = 10, p = 19, f = 9, m = 16 }

    /// Defaults: ⌘⌥ keyboard chords (Mac-only, off the host's key space; ⌘⌥⇧ for mute) + Start+Select controller combos.
    public static let defaults = Keybindings(
        keyboard: [
            .toggleOverlayMenu: KeyChord(modifiers: [.command, .option], scancode: SC.m, keyLabel: "M"),
            .endStream: KeyChord(modifiers: [.command, .option], scancode: SC.q, keyLabel: "Q"),
            .toggleStats: KeyChord(modifiers: [.command, .option], scancode: SC.s, keyLabel: "S"),
            .toggleInputCapture: KeyChord(modifiers: [.command, .option], scancode: SC.g, keyLabel: "G"),
            .toggleMouseMode: KeyChord(modifiers: [.command, .option], scancode: SC.p, keyLabel: "P"),
            .toggleFullscreen: KeyChord(modifiers: [.command, .option], scancode: SC.f, keyLabel: "F"),
            .toggleMute: KeyChord(modifiers: [.command, .option, .shift], scancode: SC.m, keyLabel: "M"),
        ],
        gamepad: [
            .toggleOverlayMenu: GamepadChord([.start, .select, .dpadUp]),
            .endStream: GamepadChord([.start, .select, .b]),
            .toggleStats: GamepadChord([.start, .select, .y]),
            .toggleMouseMode: GamepadChord([.start, .select, .x]),
            .toggleInputCapture: GamepadChord([.start, .select, .a]),
            .toggleMute: GamepadChord([.start, .select, .dpadDown]),
        ])

    /// Action bound to an exact keyboard chord (modifiers + scancode), or nil.
    public func action(forKeyboardModifiers modifiers: ChordModifiers, scancode: Int) -> StreamAction? {
        guard scancode != 0 else { return nil }
        return keyboard.first { $0.value.modifiers == modifiers && $0.value.scancode == scancode }?.key
    }

    /// Action bound to an exact controller combo (full button set), or nil.
    public func action(forGamepad buttons: Set<GamepadChordButton>) -> StreamAction? {
        guard !buttons.isEmpty else { return nil }
        return gamepad.first { $0.value.buttons == buttons }?.key
    }

    /// Other actions already bound to `chord` on the keyboard (for conflict warnings).
    public func keyboardConflicts(_ chord: KeyChord, excluding action: StreamAction) -> [StreamAction] {
        guard !chord.isEmpty else { return [] }
        return keyboard.filter { $0.key != action && $0.value.modifiers == chord.modifiers && $0.value.scancode == chord.scancode }
            .map(\.key)
    }

    /// Other actions already bound to `chord` on the controller (for conflict warnings).
    public func gamepadConflicts(_ chord: GamepadChord, excluding action: StreamAction) -> [StreamAction] {
        guard !chord.isEmpty else { return [] }
        return gamepad.filter { $0.key != action && $0.value.buttons == chord.buttons }.map(\.key)
    }

    /// Bind (or clear with `.none`/nil) the keyboard chord for an action.
    public mutating func setKeyboard(_ chord: KeyChord?, for action: StreamAction) {
        if let chord, !chord.isEmpty { keyboard[action] = chord } else { keyboard[action] = nil }
    }

    /// Bind (or clear with `.none`/nil) the controller combo for an action.
    public mutating func setGamepad(_ chord: GamepadChord?, for action: StreamAction) {
        if let chord, !chord.isEmpty { gamepad[action] = chord } else { gamepad[action] = nil }
    }

    /// Defaults for actions absent from persisted data (documents saved before an action existed). Persisted chords win.
    public func fillingMissingDefaults() -> Keybindings {
        Keybindings(
            keyboard: Self.defaults.keyboard.merging(keyboard) { _, persisted in persisted },
            gamepad: Self.defaults.gamepad.merging(gamepad) { _, persisted in persisted })
    }
}

extension StreamAction: CodingKeyRepresentable {
    public init?<T: CodingKey>(codingKey: T) { self.init(rawValue: codingKey.stringValue) }
    public var codingKey: any CodingKey { StringCodingKey(rawValue) }
}

private struct StringCodingKey: CodingKey {
    let stringValue: String
    init(_ value: String) { stringValue = value }
    init?(stringValue: String) { self.stringValue = stringValue }
    var intValue: Int? { nil }
    init?(intValue: Int) { return nil }
}

/// Global input preferences: pointer mode, hotkeys, button swaps, and
/// PlayStation controller settings.
public struct InputPreferences: Codable, Equatable, Sendable {
    public var mouseMode: MouseMode
    public var keybindings: Keybindings
    public var playStationEmulation: PlayStationControllerEmulation
    public var playStationLEDColor: PlayStationLEDColor
    public var showControllerBatteryPercentage: Bool
    public var swapFaceButtons: Bool
    public var swapMouseButtons: Bool
    public var swapWinAltKeys: Bool

    public init(mouseMode: MouseMode = .game, keybindings: Keybindings = .defaults,
                playStationEmulation: PlayStationControllerEmulation = .playStation4,
                playStationLEDColor: PlayStationLEDColor = .blue,
                showControllerBatteryPercentage: Bool = false,
                swapFaceButtons: Bool = false, swapMouseButtons: Bool = false,
                swapWinAltKeys: Bool = false) {
        self.mouseMode = mouseMode
        self.keybindings = keybindings
        self.playStationEmulation = playStationEmulation
        self.playStationLEDColor = playStationLEDColor
        self.showControllerBatteryPercentage = showControllerBatteryPercentage
        self.swapFaceButtons = swapFaceButtons
        self.swapMouseButtons = swapMouseButtons
        self.swapWinAltKeys = swapWinAltKeys
    }

    // Custom decode so preferences written before a field existed load with that field's default.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mouseMode = try c.decode(MouseMode.self, forKey: .mouseMode)
        keybindings = try c.decode(Keybindings.self, forKey: .keybindings)
        playStationEmulation = try c.decodeIfPresent(
            PlayStationControllerEmulation.self, forKey: .playStationEmulation) ?? .playStation4
        playStationLEDColor = try c.decodeIfPresent(
            PlayStationLEDColor.self, forKey: .playStationLEDColor) ?? .blue
        showControllerBatteryPercentage = try c.decodeIfPresent(
            Bool.self, forKey: .showControllerBatteryPercentage) ?? false
        swapFaceButtons = try c.decode(Bool.self, forKey: .swapFaceButtons)
        swapMouseButtons = try c.decode(Bool.self, forKey: .swapMouseButtons)
        swapWinAltKeys = try c.decodeIfPresent(Bool.self, forKey: .swapWinAltKeys) ?? false
    }

    public static let defaults = InputPreferences()
}
