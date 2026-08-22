import Foundation
import Testing
@testable import AsteriaModel

@Suite("App library composition")
struct AppLibraryTests {
    private let apps: [(appId: String, title: String)] = [
        ("1", "Desktop"),
        ("2", "Cyberpunk 2077"),
        ("3", "Hades"),
        ("4", "Steam Big Picture"),
    ]

    @Test("Running app sorts first")
    func runningFirst() {
        let entries = AppLibrary.compose(apps: apps, runningAppId: "3")
        #expect(entries.first?.appId == "3")
        #expect(entries.first?.isRunning == true)
        #expect(entries.filter(\.isRunning).count == 1)
    }

    @Test("Played apps sort most-recent first, ahead of never-played")
    func recencyOrder() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let recency = ["2": now, "4": now.addingTimeInterval(-3600)]
        let entries = AppLibrary.compose(apps: apps, recency: recency)
        #expect(entries.map(\.appId) == ["2", "4", "1", "3"])
    }

    @Test("Running app outranks a more-recently-played app")
    func runningBeatsRecency() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let entries = AppLibrary.compose(apps: apps, recency: ["2": now], runningAppId: "3")
        #expect(entries.map(\.appId).prefix(2) == ["3", "2"])
    }

    @Test("Never-played apps keep applist order")
    func stableForUnplayed() {
        let entries = AppLibrary.compose(apps: apps)
        #expect(entries.map(\.appId) == ["1", "2", "3", "4"])
    }

    @Test("Desktop is flagged case-insensitively")
    func desktopFlag() {
        let entries = AppLibrary.compose(apps: [("9", "desktop"), ("2", "Hades")])
        #expect(entries.first { $0.appId == "9" }?.isDesktop == true)
        #expect(entries.first { $0.appId == "2" }?.isDesktop == false)
    }

    @Test("Search filters by case-insensitive title substring")
    func searchFilter() {
        let entries = AppLibrary.compose(apps: apps)
        #expect(AppLibrary.filter(entries, query: "cyber").map(\.appId) == ["2"])
        #expect(AppLibrary.filter(entries, query: "  ").count == entries.count)
        #expect(AppLibrary.filter(entries, query: "steam").map(\.title) == ["Steam Big Picture"])
    }
}
