import Foundation
import Testing
@testable import AsteriaKit

@Suite("Host Roster")
struct HostRosterTests {
    @Test("discovery reconciles availability and persists the Host Profile")
    func discoveryPersistsProfile() async throws {
        let initial = HostRecord(
            id: "living-room",
            hostUniqueId: "host-1",
            name: "Old Name",
            address: "192.168.1.10"
        )
        let repository = InMemoryLibraryRepository(LibraryDocument(hosts: [initial]))
        let store = LibraryDocumentStore(repository: repository)
        let browser = FixedDiscoveryBrowser(
            hosts: [DiscoveredHost(name: "Living Room", address: "192.168.1.20")]
        )
        let poller = FixedHostInfoPoller(infos: [
            "192.168.1.20": HostInfo(
                uniqueId: "host-1",
                hostname: "Living Room",
                isBusy: false,
                hostSoftware: .foundationSunshine
            ),
            "192.168.1.10": HostInfo(
                uniqueId: "host-1",
                hostname: "Living Room",
                isBusy: false,
                hostSoftware: .foundationSunshine
            ),
        ])
        let roster = HostRoster(store: store, browser: browser, poller: poller)

        _ = try await roster.load()
        let refreshed = try await roster.refresh(now: Date(timeIntervalSince1970: 100))

        #expect(refreshed.profiles.first?.address == "192.168.1.20")
        #expect(refreshed.profiles.first?.hostSoftware == .foundationSunshine)
        #expect(refreshed.availability["living-room"] == .online)

        let reloaded = HostRoster(store: LibraryDocumentStore(repository: repository),
                                  browser: browser, poller: poller)
        #expect(try await reloaded.load().profiles.first?.address == "192.168.1.20")
    }
}

private struct FixedDiscoveryBrowser: HostDiscoveryBrowser {
    let hosts: [DiscoveredHost]
    func scan(forSeconds seconds: Double) async -> [DiscoveredHost] { hosts }
}

private struct FixedHostInfoPoller: HostInfoPoller {
    let infos: [String: HostInfo]
    func fetchInfo(address: String) async -> HostInfo? { infos[address] }
}
