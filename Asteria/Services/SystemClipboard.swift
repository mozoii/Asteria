import AppKit

/// The local clipboard, read by the stream's clipboard-sync loop. A protocol so the loop can be driven by a fake.
@MainActor
protocol ClipboardSource {
    /// Monotonic counter that changes whenever the clipboard is written; drives change detection.
    var changeCount: Int { get }
    func string() -> String?
}

struct SystemClipboard: ClipboardSource {
    var changeCount: Int { NSPasteboard.general.changeCount }
    func string() -> String? { NSPasteboard.general.string(forType: .string) }
}
