import Foundation

/// A library card: the host's app plus display state (running/desktop/recency).
public struct AppLibraryEntry: Equatable, Sendable, Identifiable {
    public var id: String { appId }
    public var appId: String
    public var title: String
    public var isRunning: Bool
    public var isDesktop: Bool
    public var lastPlayed: Date?

    public init(appId: String, title: String, isRunning: Bool = false,
                isDesktop: Bool = false, lastPlayed: Date? = nil) {
        self.appId = appId
        self.title = title
        self.isRunning = isRunning
        self.isDesktop = isDesktop
        self.lastPlayed = lastPlayed
    }
}

public enum AppLibrary {
    /// Order library entries from the host applist, persisted recency, and the running app id.
    /// Running app first (so Resume is prominent), then most-recent, then applist order.
    public static func compose(
        apps: [(appId: String, title: String)],
        recency: [String: Date] = [:],
        runningAppId: String? = nil
    ) -> [AppLibraryEntry] {
        let indexed = apps.enumerated().map { offset, app in
            (offset, AppLibraryEntry(
                appId: app.appId,
                title: app.title,
                isRunning: runningAppId != nil && app.appId == runningAppId,
                isDesktop: app.title.caseInsensitiveCompare("Desktop") == .orderedSame,
                lastPlayed: recency[app.appId]))
        }
        return indexed.sorted { lhs, rhs in
            let a = lhs.1, b = rhs.1
            if a.isRunning != b.isRunning { return a.isRunning }
            switch (a.lastPlayed, b.lastPlayed) {
            case let (l?, r?) where l != r: return l > r
            case (_?, nil): return true
            case (nil, _?): return false
            default: return lhs.0 < rhs.0
            }
        }.map(\.1)
    }

    /// Case-insensitive title substring filter; blank query returns everything unchanged.
    public static func filter(_ entries: [AppLibraryEntry], query: String) -> [AppLibraryEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return entries }
        return entries.filter { $0.title.range(of: trimmed, options: .caseInsensitive) != nil }
    }
}
