import Testing
@testable import AsteriaKit

@Suite("Settings Editor")
@MainActor
struct SettingsEditorTests {
    @Test("one editor persists stream, input, and overlay preferences")
    func persistsAllSettingsFamilies() async throws {
        let repository = InMemoryLibraryRepository()
        let store = LibraryDocumentStore(repository: repository)
        let roster = HostRoster(
            store: store,
            browser: EmptyBrowser(),
            poller: EmptyPoller()
        )
        let editor = SettingsEditor(
            scope: .global,
            document: .empty,
            capabilities: .unrestricted,
            store: store,
            roster: roster,
            identities: ClientIdentityVault(secretStore: InMemorySecretStore())
        )

        editor.draft.frameRate = .fps(75)
        editor.inputPreferences.swapMouseButtons = true
        editor.overlayPreferences.showNetworkLatency = false
        await editor.commitStream()
        await editor.commitInput()
        await editor.commitOverlay()

        let saved = try await store.snapshot()
        #expect(saved.globalSettings.frameRate == .fps(75))
        #expect(saved.inputPreferences.swapMouseButtons)
        #expect(!saved.overlayPreferences.showNetworkLatency)
    }
}

private struct EmptyBrowser: HostDiscoveryBrowser {
    func scan(forSeconds: Double) async -> [DiscoveredHost] { [] }
}

private struct EmptyPoller: HostInfoPoller {
    func fetchInfo(address: String) async -> HostInfo? { nil }
}
