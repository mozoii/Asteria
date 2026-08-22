import Foundation
import Testing
@testable import AsteriaModel


@Suite("What's New presentation decision")
struct WhatsNewDecisionTests {
    @Test("First install never shows (lastSeen nil), so the version is recorded silently")
    func firstInstall() {
        #expect(!WhatsNewDecision.shouldPresent(current: "0.2", lastSeen: nil, override: .none))
    }

    @Test("A version bump shows once")
    func versionBump() {
        #expect(WhatsNewDecision.shouldPresent(current: "0.3", lastSeen: "0.2", override: .none))
    }

    @Test("Same version does not re-show")
    func sameVersion() {
        #expect(!WhatsNewDecision.shouldPresent(current: "0.2", lastSeen: "0.2", override: .none))
    }

    @Test("Override forces show or hide regardless of versions")
    func overrides() {
        #expect(WhatsNewDecision.shouldPresent(current: "0.2", lastSeen: "0.2", override: .forceShow))
        #expect(!WhatsNewDecision.shouldPresent(current: "0.3", lastSeen: "0.2", override: .forceHide))
        #expect(WhatsNewDecision.shouldPresent(current: "0.2", lastSeen: nil, override: .forceShow))
    }

    @Test("Override parses the env var")
    func overrideParsing() {
        #expect(WhatsNewOverride(environment: ["ASTERIA_SHOW_CHANGES": "1"]) == .forceShow)
        #expect(WhatsNewOverride(environment: ["ASTERIA_SHOW_CHANGES": "0"]) == .forceHide)
        #expect(WhatsNewOverride(environment: [:]) == .none)
        #expect(WhatsNewOverride(environment: ["ASTERIA_SHOW_CHANGES": "yes"]) == .none)
    }
}

@Suite("Release entry decoding and ordering")
struct ChangelogTests {
    private let json = """
    { "version": "0.1.0", "items": [
      { "kind": "experimental", "symbol": "flask", "title": "New thing", "text": "b" },
      { "kind": "new", "symbol": "bolt", "title": "A", "text": "a" },
      { "kind": "known", "symbol": "x", "title": "Bug", "text": "k" },
      { "kind": "fixed", "symbol": "check", "title": "C", "text": "c" }
    ] }
    """

    private func entry() throws -> ReleaseEntry {
        try ReleaseEntry(data: Data(json.utf8))
    }

    @Test("Decodes a per-version release file")
    func decode() throws {
        #expect(try entry().version == "0.1.0")
        #expect(try entry().items.count == 4)
    }

    @Test("Every kind renders in canonical category order")
    func ordering() throws {
        #expect(try entry().orderedItems().map(\.kind) == [.new, .fixed, .known, .experimental])
    }

    @Test("Missing or empty text falls back to the title")
    func textFallsBackToTitle() throws {
        let json = """
        { "version": "1.0", "items": [
          { "kind": "new", "symbol": "bolt", "title": "Solo entry" },
          { "kind": "new", "symbol": "bolt", "title": "Blank", "text": "" },
          { "kind": "new", "symbol": "bolt", "title": "Detailed", "text": "Has detail." }
        ] }
        """
        let items = try ReleaseEntry(data: Data(json.utf8)).items
        #expect(items[0].text == "Solo entry")
        #expect(items[1].text == "Blank")
        #expect(items[2].text == "Has detail.")
    }
}
