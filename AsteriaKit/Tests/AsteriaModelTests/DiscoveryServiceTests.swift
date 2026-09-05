import Foundation
import Testing
@testable import AsteriaModel

private struct FakeBrowser: HostDiscoveryBrowser {
    let hosts: [DiscoveredHost]
    func scan(forSeconds seconds: Double) async -> [DiscoveredHost] { hosts }
}

private struct FakePoller: HostInfoPoller {
    let infos: [String: HostInfo]   // address → info; a missing address is unreachable
    func fetchInfo(address: String) async -> HostInfo? { infos[address] }
}

private final class CountingPoller: HostInfoPoller, @unchecked Sendable {
    let infos: [String: HostInfo]
    private let lock = NSLock()
    private(set) var calls: [String: Int] = [:]
    init(_ infos: [String: HostInfo]) { self.infos = infos }
    func fetchInfo(address: String) async -> HostInfo? {
        lock.withLock { calls[address, default: 0] += 1 }
        return infos[address]
    }
}

@Suite("Discovery service")
struct DiscoveryServiceTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    @Test("a bonjour scan reconciles hosts and reports availability")
    func bonjourScan() async {
        let browser = FakeBrowser(hosts: [DiscoveredHost(name: "PC1", address: "10.0.0.1"),
                                          DiscoveredHost(name: "PC2", address: "10.0.0.2")])
        let poller = FakePoller(infos: [
            "10.0.0.1": HostInfo(uniqueId: "uid1", hostname: "PC1", isBusy: false),
            "10.0.0.2": HostInfo(uniqueId: "uid2", hostname: "PC2", isBusy: true),
        ])
        let result = await DiscoveryService(browser: browser, poller: poller).scan(roster: [], now: now)
        #expect(result.hosts.count == 2)
        let firstID = result.hosts.first { $0.hostUniqueId == "uid1" }?.id
        let secondID = result.hosts.first { $0.hostUniqueId == "uid2" }?.id
        #expect(firstID.flatMap { result.availability[$0] } == .online)
        #expect(secondID.flatMap { result.availability[$0] } == .busy)
    }

    @Test("a known roster host not seen by bonjour is still polled and retained when offline")
    func knownRosterPolled() async {
        let known = HostRecord(id: "uid9", name: "Old", address: "10.0.0.9", isPaired: true)
        let service = DiscoveryService(browser: FakeBrowser(hosts: []), poller: FakePoller(infos: [:]))
        let result = await service.scan(roster: [known], now: now)
        #expect(result.hosts.contains { $0.id == "uid9" })
        #expect(result.availability["uid9"] == .offline)
    }

    @Test("a bonjour sighting adopts an unpaired placeholder's id")
    func adoptsPlaceholderId() async {
        let placeholder = HostRecord(id: "local-uuid", name: "typed", address: "10.0.0.5",
                                     manualAddress: "10.0.0.5", isPaired: false)
        let browser = FakeBrowser(hosts: [DiscoveredHost(name: "RealPC", address: "10.0.0.5")])
        let poller = FakePoller(infos: ["10.0.0.5": HostInfo(uniqueId: "real-uid", hostname: "RealPC", isBusy: false)])
        let result = await DiscoveryService(browser: browser, poller: poller).scan(roster: [placeholder], now: now)
        #expect(result.hosts.contains { $0.id == "local-uuid" && $0.hostUniqueId == "real-uid" })
        #expect(result.availability["local-uuid"] == .online)
    }

    @Test("a known manual address also seen by bonjour is polled once")
    func manualDedup() async {
        let known = HostRecord(id: "uid5", name: "PC", address: "10.0.0.5",
                               manualAddress: "10.0.0.5", isPaired: true)
        let browser = FakeBrowser(hosts: [DiscoveredHost(name: "PC", address: "10.0.0.5")])
        let poller = CountingPoller(["10.0.0.5": HostInfo(uniqueId: "uid5", hostname: "PC", isBusy: false)])
        _ = await DiscoveryService(browser: browser, poller: poller).scan(roster: [known], now: now)
        #expect(poller.calls["10.0.0.5"] == 1)
    }

    @Test("a manual address that resolves is added online")
    func addManualHappy() async throws {
        let poller = FakePoller(infos: ["10.0.0.7": HostInfo(uniqueId: "uid7", hostname: "Box", isBusy: false)])
        let service = DiscoveryService(browser: FakeBrowser(hosts: []), poller: poller)
        let result = try #require(await service.addManual(rawAddress: "  http://10.0.0.7/  ", roster: [], now: now))
        let host = try #require(result.hosts.first { $0.hostUniqueId == "uid7" })
        #expect(result.availability[host.id] == .online)
    }

    @Test("manually adding one physical host twice creates two client configurations")
    func addManualDuplicateConfiguration() async throws {
        let existing = HostRecord(id: "client-1", hostUniqueId: "host-1", name: "PC",
                                  address: "10.0.0.7", isPaired: true)
        let poller = FakePoller(infos: [
            "10.0.0.7": HostInfo(uniqueId: "host-1", hostname: "PC", isBusy: false,
                                 hostSoftware: .apolloFamily),
        ])
        let service = DiscoveryService(browser: FakeBrowser(hosts: []), poller: poller)

        let result = try #require(
            await service.addManual(rawAddress: "10.0.0.7", roster: [existing], now: now))

        #expect(result.hosts.count == 2)
        #expect(Set(result.hosts.compactMap(\.hostUniqueId)) == ["host-1"])
        #expect(Set(result.hosts.map(\.id)).count == 2)
        #expect(result.hosts.allSatisfy { $0.hostSoftware == .apolloFamily })
    }

    @Test("a blank manual address is rejected")
    func addManualInvalid() async {
        let service = DiscoveryService(browser: FakeBrowser(hosts: []), poller: FakePoller(infos: [:]))
        #expect(await service.addManual(rawAddress: "   ", roster: [], now: now) == nil)
    }

    @Test("a manual address that fails to poll is still added offline")
    func addManualOffline() async throws {
        let service = DiscoveryService(browser: FakeBrowser(hosts: []), poller: FakePoller(infos: [:]))
        let result = try #require(await service.addManual(rawAddress: "10.0.0.8", roster: [], now: now))
        let host = try #require(result.hosts.first { $0.address == "10.0.0.8" })
        #expect(result.availability[host.id] == .offline)
    }

    @Test("a forgotten host seen by bonjour is excluded from the scan")
    func forgottenExcluded() async {
        let browser = FakeBrowser(hosts: [DiscoveredHost(name: "PC1", address: "10.0.0.1"),
                                          DiscoveredHost(name: "PC2", address: "10.0.0.2")])
        let poller = FakePoller(infos: [
            "10.0.0.1": HostInfo(uniqueId: "uid1", hostname: "PC1", isBusy: false),
            "10.0.0.2": HostInfo(uniqueId: "uid2", hostname: "PC2", isBusy: false),
        ])
        let result = await DiscoveryService(browser: browser, poller: poller)
            .scan(roster: [], forgotten: ["uid1"], now: now)
        #expect(!result.hosts.contains { $0.hostUniqueId == "uid1" })
        #expect(result.hosts.contains { $0.hostUniqueId == "uid2" })
        #expect(result.availability.keys.allSatisfy { id in
            result.hosts.contains { $0.id == id }
        })
    }

    @Test("a forgotten host is excluded by address even when it reappears with a new id")
    func forgottenByAddress() async {
        let browser = FakeBrowser(hosts: [DiscoveredHost(name: "PC1", address: "10.0.0.1")])
        let poller = FakePoller(infos: ["10.0.0.1": HostInfo(uniqueId: "uid1", hostname: "PC1", isBusy: false)])
        let result = await DiscoveryService(browser: browser, poller: poller)
            .scan(roster: [], forgotten: ["10.0.0.1"], now: now)
        #expect(result.hosts.isEmpty)
    }

    @Test("reconciled hosts are stamped with the injected date")
    func nowInjection() async {
        let browser = FakeBrowser(hosts: [DiscoveredHost(name: "PC", address: "10.0.0.1")])
        let poller = FakePoller(infos: ["10.0.0.1": HostInfo(uniqueId: "uid1", hostname: "PC", isBusy: false)])
        let result = await DiscoveryService(browser: browser, poller: poller).scan(roster: [], now: now)
        #expect(result.hosts.first?.lastSeen == now)
    }

    @Test("isForgotten matches a host by id, unique id, address, or manual address")
    func isForgottenPredicate() {
        let host = HostRecord(
            id: "client-1",
            hostUniqueId: "host-1",
            name: "PC",
            address: "10.0.0.7",
            manualAddress: "10.0.0.7"
        )
        #expect(DiscoveryService.isForgotten(host, in: ["client-1"]))
        #expect(DiscoveryService.isForgotten(host, in: ["host-1"]))
        #expect(DiscoveryService.isForgotten(host, in: ["10.0.0.7"]))
        #expect(!DiscoveryService.isForgotten(host, in: ["unrelated"]))
        #expect(!DiscoveryService.isForgotten(host, in: []))

        let noUID = HostRecord(id: "client-2", name: "X", address: "10.0.0.9")
        #expect(!DiscoveryService.isForgotten(noUID, in: ["some-uid"]))   // nil uniqueId never matches a key
        #expect(DiscoveryService.isForgotten(noUID, in: ["10.0.0.9"]))
    }
}
