import UIKit

/// The local clipboard, read by the stream's clipboard-sync loop.
///
/// iOS shows a "pasted from" banner each time an app reads the pasteboard's contents, so the sync
/// loop's change-count check matters more here than on macOS: reading `string` only after
/// `changeCount` moves keeps the banner to one per actual copy rather than one per poll.
struct SystemClipboard: ClipboardSource {
    var changeCount: Int { UIPasteboard.general.changeCount }
    func string() -> String? { UIPasteboard.general.string }
}
