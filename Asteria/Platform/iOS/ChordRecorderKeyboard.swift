import UIKit
import SwiftUI
import AsteriaKit

/// Keyboard capture for the rebind sheet. iOS has no global event monitor, so presses reach the
/// recorder through `KeyPressCaptureView`, a first responder the sheet mounts while it is open.
/// It never calls `super`, which is how a chord being recorded is stopped from also firing the real
/// shortcut, the same guarantee the Mac's swallowing event monitor gives.
extension ChordRecorder {
    /// Nothing to install globally: the sheet mounts the responder view instead.
    func startKeyboard() {}
    func stopKeyboard() { keyMonitor = nil }

    /// One key press from the responder. `UIKeyboardHIDUsage` is already a USB HID usage on page
    /// 0x07, which is exactly the domain `KeyChord.scancode` and the wire protocol use.
    func ingest(press key: UIKey) {
        let modifiers = Self.modifiers(key.modifierFlags)
        recordLiveModifiers(modifiers)
        guard !Self.isModifierKey(key.keyCode) else { return }
        if key.keyCode == .keyboardEscape {
            cancelFromKeyboard()
            return
        }
        let scancode = Int(key.keyCode.rawValue)
        recordKeyChord(KeyChord(modifiers: modifiers, scancode: scancode,
                                keyLabel: Self.label(for: scancode, key: key)))
    }

    /// A modifier-only press updates the live glyphs; releasing them all clears the preview.
    func ingestModifiers(_ flags: UIKeyModifierFlags) {
        recordLiveModifiers(Self.modifiers(flags))
    }

    private static func modifiers(_ flags: UIKeyModifierFlags) -> ChordModifiers {
        var mods: ChordModifiers = []
        if flags.contains(.command) { mods.insert(.command) }
        if flags.contains(.alternate) { mods.insert(.option) }
        if flags.contains(.control) { mods.insert(.control) }
        if flags.contains(.shift) { mods.insert(.shift) }
        return mods
    }

    private static func isModifierKey(_ code: UIKeyboardHIDUsage) -> Bool {
        switch code {
        case .keyboardLeftControl, .keyboardRightControl,
             .keyboardLeftShift, .keyboardRightShift,
             .keyboardLeftAlt, .keyboardRightAlt,
             .keyboardLeftGUI, .keyboardRightGUI:
            return true
        default:
            return false
        }
    }

    private static func label(for scancode: Int, key: UIKey) -> String {
        if let named = namedLabels[scancode] { return named }
        let characters = key.charactersIgnoringModifiers
        if let first = characters.unicodeScalars.first, first.value >= 0x20, first.value != 0x7F {
            return characters.uppercased()
        }
        return "Key \(scancode)"
    }
}

/// A first responder that consumes hardware key presses and hands them to the recorder.
struct KeyPressCaptureView: UIViewRepresentable {
    let recorder: ChordRecorder

    func makeUIView(context: Context) -> KeyCaptureUIView {
        let view = KeyCaptureUIView()
        view.recorder = recorder
        return view
    }

    func updateUIView(_ uiView: KeyCaptureUIView, context: Context) {
        uiView.recorder = recorder
    }
}

final class KeyCaptureUIView: UIView {
    weak var recorder: ChordRecorder?

    override var canBecomeFirstResponder: Bool { true }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        // SwiftUI installs its own responder during presentation; claim focus after that settles.
        DispatchQueue.main.async { [weak self] in _ = self?.becomeFirstResponder() }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses {
            guard let key = press.key else { continue }
            recorder?.ingest(press: key)
            handled = true
        }
        // Deliberately not forwarding to super for handled presses: an unswallowed ⌘W while
        // recording would dismiss the sheet instead of binding the chord.
        if !handled { super.pressesBegan(presses, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses where press.key != nil {
            recorder?.ingestModifiers(press.key!.modifierFlags)
        }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        recorder?.ingestModifiers([])
    }
}

extension View {
    /// iOS has no global key monitor, so the sheet hosts a first responder that swallows presses and
    /// feeds them to the recorder. Zero-sized: it exists to hold focus, not to be seen.
    @ViewBuilder func keyChordCapture(_ recorder: ChordRecorder, isActive: Bool) -> some View {
        if isActive {
            background { KeyPressCaptureView(recorder: recorder).frame(width: 0, height: 0) }
        } else {
            self
        }
    }
}
