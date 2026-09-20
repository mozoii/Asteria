import AppKit
import SwiftUI
import AsteriaKit

/// Keyboard capture for the rebind sheet: a local event monitor that swallows every key press so a
/// chord being recorded can't also fire the real shortcut (⌘Q would otherwise quit mid-capture).
extension ChordRecorder {
    func startKeyboard() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            recordLiveModifiers(Self.modifiers(event.modifierFlags))
            if event.type == .flagsChanged { return nil }
            if event.keyCode == 53 { cancelFromKeyboard(); return event }
            if let chord = Self.chord(from: event) { recordKeyChord(chord) }
            return nil
        }
    }

    func stopKeyboard() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
    }

    private static func modifiers(_ f: NSEvent.ModifierFlags) -> ChordModifiers {
        var mods: ChordModifiers = []
        if f.contains(.command) { mods.insert(.command) }
        if f.contains(.option) { mods.insert(.option) }
        if f.contains(.control) { mods.insert(.control) }
        if f.contains(.shift) { mods.insert(.shift) }
        return mods
    }

    private static func chord(from event: NSEvent) -> KeyChord? {
        guard let scancode = virtualToHID[event.keyCode] else { return nil }
        return KeyChord(modifiers: modifiers(event.modifierFlags), scancode: scancode,
                        keyLabel: label(for: scancode, event: event))
    }

    private static func label(for scancode: Int, event: NSEvent) -> String {
        if let named = namedLabels[scancode] { return named }
        if let chars = event.charactersIgnoringModifiers, let first = chars.unicodeScalars.first,
           first.value >= 0x20, first.value != 0x7F {
            return chars.uppercased()
        }
        return "Key \(scancode)"
    }

    /// macOS virtual key codes are their own domain; the wire and the keybinding model both speak USB
    /// HID usages (page 0x07), which is what `GCKeyCode.rawValue` and `UIKeyboardHIDUsage` already are.
    private static let virtualToHID: [UInt16: Int] = [
        0x00: 4, 0x0B: 5, 0x08: 6, 0x02: 7, 0x0E: 8, 0x03: 9, 0x05: 10, 0x04: 11,    // A B C D E F G H
        0x22: 12, 0x26: 13, 0x28: 14, 0x25: 15, 0x2E: 16, 0x2D: 17, 0x1F: 18, 0x23: 19, // I J K L M N O P
        0x0C: 20, 0x0F: 21, 0x01: 22, 0x11: 23, 0x20: 24, 0x09: 25, 0x0D: 26, 0x07: 27, // Q R S T U V W X
        0x10: 28, 0x06: 29,                                                              // Y Z
        0x12: 30, 0x13: 31, 0x14: 32, 0x15: 33, 0x17: 34, 0x16: 35, 0x1A: 36, 0x1C: 37, // 1–8
        0x19: 38, 0x1D: 39,                                                              // 9 0
        0x24: 40, 0x35: 41, 0x33: 42, 0x30: 43, 0x31: 44,                                // Return Esc Delete Tab Space
        0x1B: 45, 0x18: 46, 0x21: 47, 0x1E: 48, 0x2A: 49,                                // - = [ ] \
        0x29: 51, 0x27: 52, 0x32: 53, 0x2B: 54, 0x2F: 55, 0x2C: 56,                      // ; ' ` , . /
        0x7A: 58, 0x78: 59, 0x63: 60, 0x76: 61, 0x60: 62, 0x61: 63, 0x62: 64, 0x64: 65, // F1–F8
        0x65: 66, 0x6D: 67, 0x67: 68, 0x6F: 69,                                          // F9–F12
        0x7B: 80, 0x7C: 79, 0x7D: 81, 0x7E: 82,                                          // ← → ↓ ↑
    ]
}

extension View {
    /// macOS captures keys with a global event monitor `ChordRecorder` installs itself, so the sheet
    /// needs nothing mounted in its view tree.
    func keyChordCapture(_ recorder: ChordRecorder, isActive: Bool) -> some View { self }
}
