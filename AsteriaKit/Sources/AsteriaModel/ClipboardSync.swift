/// Decides when the local clipboard should be pushed to the host, from the pasteboard's monotonic change-count.
/// Pure and value-typed so the polling loop that owns an `NSPasteboard` stays a thin, untested shell.
public struct ClipboardSyncModel: Sendable {
    /// -1 so the first poll always syncs, letting the host pick up whatever is on the clipboard when sync is enabled.
    private var lastSyncedChangeCount = -1

    public init() {}

    /// The text to push, or nil when the clipboard is unchanged or holds no text. Records the change-count either
    /// way, so a non-text change isn't retried and doesn't mask the next real edit.
    public mutating func textToSync(changeCount: Int, text: String?) -> String? {
        guard changeCount != lastSyncedChangeCount else { return nil }
        lastSyncedChangeCount = changeCount
        guard let text, !text.isEmpty else { return nil }
        return text
    }
}
