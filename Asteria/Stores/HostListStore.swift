import Foundation
import Observation
import AsteriaKit

/// Observable app adapter over the headless Host Roster and shared document store.
@MainActor
@Observable
final class HostListStore {
    private(set) var hosts: [HostRecord] = []
    private(set) var availability: [String: HostAvailability] = [:]
    private(set) var isScanning = false
    private(set) var loadError: String?

    let documentStore: LibraryDocumentStore
    let roster: HostRoster
    private var document = LibraryDocument.empty

    init(repository: any LibraryRepository) {
        let documentStore = LibraryDocumentStore(repository: repository)
        self.documentStore = documentStore
        self.roster = HostRoster(
            store: documentStore,
            browser: NWBrowserDiscovery(),
            poller: ServerInfoPoller()
        )
    }

    func availability(for host: HostRecord) -> HostAvailability { availability[host.id] ?? .unknown }

    func load() async {
        do {
            async let loadedDocument = documentStore.snapshot()
            async let loadedRoster = roster.load()
            document = try await loadedDocument
            apply(try await loadedRoster)
        } catch {
            loadError = "Couldn't load saved PCs: \(error.localizedDescription) "
                + "Restore or remove ~/Library/Application Support/Asteria/library.json, "
                + "then relaunch Asteria."
        }
    }

    func dismissLoadError() { loadError = nil }

    /// Bonjour scan + serverinfo poll of every discovered and known address; reconcile + persist.
    func refresh() async {
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }
        do {
            apply(try await roster.refresh())
            document = try await documentStore.snapshot()
        } catch {
            loadError = Self.persistenceMessage(operation: "refresh the Host Roster", error: error)
        }
    }

    /// Add a user-typed host: normalize, poll once, reconcile, persist.
    func addManualHost(_ raw: String) async {
        do {
            guard let state = try await roster.addManual(raw) else { return }
            apply(state)
            document = try await documentStore.snapshot()
        } catch {
            loadError = Self.persistenceMessage(operation: "add the Host Profile", error: error)
        }
    }

    /// Persist a host's pairing result (upsert) and mark it reachable.
    func markPaired(_ host: HostRecord) async {
        await applyRosterMutation(operation: "save the paired Host Profile") {
            try await roster.markPaired(host)
        }
    }

    /// Blank input restores the serverinfo hostname.
    func renameHost(_ host: HostRecord, to newName: String) async {
        await applyRosterMutation(operation: "rename the Host Profile") {
            try await roster.rename(profileID: host.id, to: newName)
        }
    }

    func forget(_ host: HostRecord) async {
        await applyRosterMutation(operation: "forget the Host Profile") {
            try await roster.forget(profileID: host.id)
        }
    }

    /// Whether the first-run setup flow has been completed.
    var isOnboardingComplete: Bool { document.isOnboardingComplete }

    func completeOnboarding() async {
        await updateDocument(operation: "save onboarding") { $0.isOnboardingComplete = true }
    }

    var globalSettings: StreamSettings { document.globalSettings }
    var settingsDocument: LibraryDocument { document }

    func updateGlobalSettings(_ settings: StreamSettings) async {
        await updateDocument(operation: "save Global Stream Settings") {
            $0.globalSettings = settings
        }
    }

    func override(for host: HostRecord) -> StreamSettingsOverride {
        document.hosts.first { $0.id == host.id }?.settingsOverride ?? host.settingsOverride
    }

    /// Global (not per-host) input preferences: pointer mode + rebindable hotkeys + button swaps.
    var inputPreferences: InputPreferences { document.inputPreferences }

    /// Global customization of the in-stream presentation settings.
    var overlayPreferences: OverlayPreferences { document.overlayPreferences }

    private func apply(_ state: HostRoster.State) {
        hosts = state.profiles
        availability = state.availability
    }

    func applySavedDocument(_ document: LibraryDocument) {
        self.document = document
        hosts = document.hosts
    }

    private func applyRosterMutation(
        operation: String,
        mutation: () async throws -> HostRoster.State
    ) async {
        do {
            apply(try await mutation())
            document = try await documentStore.snapshot()
        } catch {
            loadError = Self.persistenceMessage(operation: operation, error: error)
        }
    }

    private func updateDocument(
        operation: String,
        mutation: @escaping LibraryDocumentStore.Mutation
    ) async {
        do {
            document = try await documentStore.update(mutation)
        } catch {
            loadError = Self.persistenceMessage(operation: operation, error: error)
        }
    }

    private static func persistenceMessage(operation: String, error: Error) -> String {
        "Couldn't \(operation): \(error.localizedDescription). "
            + "Check that library.json is writable, then retry."
    }

    #if DEBUG
    /// Seeds a store with fixed hosts/availability for previews — no repository or network.
    static func preview(
        hosts: [HostRecord],
        availability: [String: HostAvailability] = [:]
    ) -> HostListStore {
        let store = HostListStore(repository: InMemoryLibraryRepository(LibraryDocument(hosts: hosts)))
        store.hosts = hosts
        store.availability = availability
        return store
    }
    #endif

}

struct NWBrowserDiscovery: HostDiscoveryBrowser {
    private let browser = HostBrowser()
    func scan(forSeconds seconds: Double) async -> [DiscoveredHost] {
        var hosts: [DiscoveredHost] = []
        for service in await browser.discover(forSeconds: seconds) {
            if let endpoint = await browser.resolve(service) {
                hosts.append(DiscoveredHost(name: service.name, address: endpoint.host))
            }
        }
        return hosts
    }
}

struct ServerInfoPoller: HostInfoPoller {
    func fetchInfo(address: String) async -> HostInfo? {
        guard let info = try? await HostPoller.fetchServerInfo(host: address) else { return nil }
        return HostInfo(uniqueId: info.uniqueId, hostname: info.hostname, isBusy: info.isBusy,
                        hostSoftware: hostSoftware(for: info))
    }

    private func hostSoftware(for info: ServerInfo) -> HostSoftware {
        if info.isFoundationSunshine { return .foundationSunshine }
        if info.isApolloFamily { return .apolloFamily }
        return .sunshineCompatible
    }
}
