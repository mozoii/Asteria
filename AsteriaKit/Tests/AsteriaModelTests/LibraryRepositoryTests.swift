import Foundation
import Testing
@testable import AsteriaModel

@Suite("Library persistence")
struct LibraryRepositoryTests {
    private func sampleDocument() -> LibraryDocument {
        var override = StreamSettingsOverride.empty
        override.resolution = .custom(width: 3440, height: 1440)
        let host = HostRecord(
            id: "41EBD0C2-0F7A-4F01-4705-29CF12056F73",
            name: "DESKTOP-EN34REH",
            address: "192.168.3.63",
            manualAddress: nil,
            isPaired: true,
            pinnedCertificate: Data([0xDE, 0xAD, 0xBE, 0xEF]),
            lastSeen: Date(timeIntervalSince1970: 1_700_000_000),
            settingsOverride: override)
        return LibraryDocument(schemaVersion: 3, globalSettings: .defaults, hosts: [host])
    }

    /// A schemaVersion-1 document whose keybindings predate the mute action (no `toggleMute` entry).
    private func legacyV1DocumentJSON() throws -> Data {
        let keyboard: [StreamAction: KeyChord] = [
            .toggleStats: KeyChord(modifiers: [.command, .option], scancode: 22, keyLabel: "S"),
            .toggleOverlayMenu: KeyChord(modifiers: [.command, .option], scancode: 16, keyLabel: "M"),
        ]
        let gamepad: [StreamAction: GamepadChord] = [
            .toggleStats: GamepadChord([.start, .select, .y]),
        ]
        let prefs = InputPreferences(keybindings: Keybindings(keyboard: keyboard, gamepad: gamepad))
        return try JSONEncoder().encode(LibraryDocument(schemaVersion: 1, inputPreferences: prefs))
    }

    @Test("v1 document missing mute chords migrates to defaults")
    func v1MigratesMissingMuteChords() throws {
        let decoded = try JSONDecoder().decode(LibraryDocument.self, from: legacyV1DocumentJSON())
        let kb = decoded.inputPreferences.keybindings
        #expect(kb.keyboard[.toggleMute] == Keybindings.defaults.keyboard[.toggleMute])   // ⌘⌥⇧M
        #expect(kb.gamepad[.toggleMute] == Keybindings.defaults.gamepad[.toggleMute])      // Start+Select+D-Down
        #expect(kb.keyboard[.toggleStats] == KeyChord(modifiers: [.command, .option], scancode: 22, keyLabel: "S"))
        #expect(decoded.schemaVersion == 3)
    }

    @Test("v1 document custom mute chord is preserved")
    func v1PreservesCustomMuteChord() throws {
        let keyboard: [StreamAction: KeyChord] = [
            .toggleStats: KeyChord(modifiers: [.command, .option], scancode: 22, keyLabel: "S"),
            .toggleMute: KeyChord(modifiers: [.control], scancode: 8, keyLabel: "E"),
        ]
        let prefs = InputPreferences(keybindings: Keybindings(keyboard: keyboard, gamepad: [:]))
        let doc = LibraryDocument(schemaVersion: 1, inputPreferences: prefs)
        let decoded = try JSONDecoder().decode(LibraryDocument.self, from: JSONEncoder().encode(doc))
        #expect(decoded.inputPreferences.keybindings.keyboard[.toggleMute]
                == KeyChord(modifiers: [.control], scancode: 8, keyLabel: "E"))
        #expect(decoded.schemaVersion == 3)
    }

    @Test("v2 document missing mute chord stays unbound")
    func v2KeepsMissingChordUnbound() throws {
        let keyboard: [StreamAction: KeyChord] = [
            .toggleStats: KeyChord(modifiers: [.command, .option], scancode: 22, keyLabel: "S"),
        ]
        let prefs = InputPreferences(keybindings: Keybindings(keyboard: keyboard, gamepad: [:]))
        let doc = LibraryDocument(schemaVersion: 2, inputPreferences: prefs)
        let decoded = try JSONDecoder().decode(LibraryDocument.self, from: JSONEncoder().encode(doc))
        #expect(decoded.inputPreferences.keybindings.keyboard[.toggleMute] == nil)
        #expect(decoded.schemaVersion == 3)
    }

    @Test("document without a schemaVersion key is treated as v1 and migrates")
    func missingSchemaVersionMigrates() throws {
        var object = try JSONSerialization.jsonObject(with: legacyV1DocumentJSON()) as! [String: Any]
        object["schemaVersion"] = nil
        let data = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(LibraryDocument.self, from: data)
        #expect(decoded.schemaVersion == 3)
        #expect(decoded.inputPreferences.keybindings.keyboard[.toggleMute]
                == Keybindings.defaults.keyboard[.toggleMute])
    }

    @Test("v2 document without forgottenHostKeys migrates to empty keys at v3")
    func v2MigratesMissingForgottenKeys() throws {
        let v2Doc = LibraryDocument(schemaVersion: 2, hosts: [HostRecord(id: "a", name: "A", address: "1")])
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(v2Doc)) as! [String: Any]
        object["forgottenHostKeys"] = nil   // a real v2 document never wrote this key
        let data = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(LibraryDocument.self, from: data)
        #expect(decoded.schemaVersion == 3)
        #expect(decoded.forgottenHostKeys.isEmpty)
        #expect(decoded.hosts.map(\.id) == ["a"])
    }

    @Test("In-memory repository round-trips a document")
    func inMemoryRoundTrip() async throws {
        let repo = InMemoryLibraryRepository()
        let doc = sampleDocument()
        try await repo.save(doc)
        #expect(try await repo.load() == doc)
    }

    @Test("In-memory load defaults to empty when nothing saved")
    func inMemoryEmptyDefault() async throws {
        let repo = InMemoryLibraryRepository()
        #expect(try await repo.load() == .empty)
    }

    @Test("JSON file repository round-trips through disk")
    func jsonFileRoundTrip() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("asteriamodel-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("library.json")
        let repo = JSONFileLibraryRepository(fileURL: url)
        let doc = sampleDocument()
        try await repo.save(doc)
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(try await repo.load() == doc)
    }

    @Test("JSON file repository preserves a non-empty forgottenHostKeys list across save/load")
    func jsonFileRoundTripForgottenKeys() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("asteriamodel-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("library.json")
        let repo = JSONFileLibraryRepository(fileURL: url)
        let doc = LibraryDocument(schemaVersion: 3, forgottenHostKeys: ["host-1", "192.168.1.10"])
        try await repo.save(doc)
        let loaded = try await repo.load()
        #expect(loaded.forgottenHostKeys == ["host-1", "192.168.1.10"])
        #expect(loaded == doc)
    }

    @Test("JSON file load returns empty when the file is absent")
    func jsonFileMissing() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("asteriamodel-missing-\(UUID().uuidString)/library.json")
        let repo = JSONFileLibraryRepository(fileURL: url)
        #expect(try await repo.load() == .empty)
    }
}
