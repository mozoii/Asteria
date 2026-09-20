import AppKit

struct SystemClipboard: ClipboardSource {
    var changeCount: Int { NSPasteboard.general.changeCount }
    func string() -> String? { NSPasteboard.general.string(forType: .string) }
}
