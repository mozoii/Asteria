@preconcurrency import GameController
import Observation
import AsteriaKit

/// Captures a live keyboard chord or controller combo for the rebind UI. Keyboard events are swallowed so
/// system shortcuts don't fire mid-capture; a controller combo finalizes when every held button is released.
///
/// The controller half is GameController on both platforms. Keyboard capture differs: macOS installs a
/// local `NSEvent` monitor, iOS routes `UIPress` through a first-responder view the sheet mounts, so
/// `startKeyboard`/`stopKeyboard` live in the platform folders.
@MainActor
@Observable
final class ChordRecorder {
    enum Kind { case keyboard, gamepad }
    let kind: Kind

    private(set) var keyChord: KeyChord = .none
    private(set) var gamepadChord: GamepadChord = .none
    /// Modifiers currently held, shown live before the user presses the final key.
    private(set) var liveModifiers: ChordModifiers = []
    /// Buttons currently held, shown live while the user presses a controller combo.
    private(set) var liveButtons: Set<GamepadChordButton> = []
    var onCancel: () -> Void = {}

    /// Opaque so the macOS event monitor and the iOS responder can each store what they need.
    var keyMonitor: Any?
    private var connectObserver: (any NSObjectProtocol)?
    private var pad: GCController?
    private var pressed: Set<GamepadChordButton> = []

    init(kind: Kind) { self.kind = kind }

    func start() {
        switch kind {
        case .keyboard: startKeyboard()
        case .gamepad: startGamepad()
        }
    }

    func stop() {
        stopKeyboard()
        if let connectObserver { NotificationCenter.default.removeObserver(connectObserver); self.connectObserver = nil }
        pad?.extendedGamepad?.valueChangedHandler = nil
        pad = nil
    }

    // MARK: - Keyboard capture, driven by the platform layer

    /// Record the completed chord; the platform layer decides what counts as a final key press.
    func recordKeyChord(_ chord: KeyChord) { keyChord = chord }

    /// Show the modifiers held so far, before the user commits to a final key.
    func recordLiveModifiers(_ modifiers: ChordModifiers) { liveModifiers = modifiers }

    /// Escape abandons the capture without binding anything.
    func cancelFromKeyboard() { onCancel() }

    /// Display labels for keys with no printable character, shared by both capture paths.
    static let namedLabels: [Int: String] = [
        40: "Return", 41: "Esc", 42: "⌫", 43: "Tab", 44: "Space",
        58: "F1", 59: "F2", 60: "F3", 61: "F4", 62: "F5", 63: "F6",
        64: "F7", 65: "F8", 66: "F9", 67: "F10", 68: "F11", 69: "F12",
        79: "→", 80: "←", 81: "↓", 82: "↑",
    ]

    // MARK: - Controller capture

    private func startGamepad() {
        if let c = GCController.controllers().first { attach(c) }
        connectObserver = NotificationCenter.default.addObserver(
            forName: .GCControllerDidConnect, object: nil, queue: nil) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.pad == nil, let c = GCController.controllers().first else { return }
                self.attach(c)
            }
        }
    }

    private func attach(_ controller: GCController) {
        guard let gp = controller.extendedGamepad else { return }
        pad = controller
        gp.valueChangedHandler = { [weak self] gp, _ in
            let held = ChordRecorder.heldButtons(gp)
            Task { @MainActor in self?.update(held) }
        }
    }

    private func update(_ held: Set<GamepadChordButton>) {
        liveButtons = held
        if held.isEmpty {
            if !pressed.isEmpty { gamepadChord = GamepadChord(pressed); pressed = [] }
        } else {
            pressed.formUnion(held)
        }
    }

    nonisolated private static func heldButtons(_ gp: GCExtendedGamepad) -> Set<GamepadChordButton> {
        var s: Set<GamepadChordButton> = []
        if gp.buttonMenu.isPressed { s.insert(.start) }
        if gp.buttonOptions?.isPressed == true { s.insert(.select) }
        if gp.buttonA.isPressed { s.insert(.a) }
        if gp.buttonB.isPressed { s.insert(.b) }
        if gp.buttonX.isPressed { s.insert(.x) }
        if gp.buttonY.isPressed { s.insert(.y) }
        if gp.leftShoulder.isPressed { s.insert(.leftShoulder) }
        if gp.rightShoulder.isPressed { s.insert(.rightShoulder) }
        if gp.leftThumbstickButton?.isPressed == true { s.insert(.leftStick) }
        if gp.rightThumbstickButton?.isPressed == true { s.insert(.rightStick) }
        if gp.dpad.up.isPressed { s.insert(.dpadUp) }
        if gp.dpad.down.isPressed { s.insert(.dpadDown) }
        if gp.dpad.left.isPressed { s.insert(.dpadLeft) }
        if gp.dpad.right.isPressed { s.insert(.dpadRight) }
        return s
    }
}
