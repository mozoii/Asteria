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

    @Test("forget removes the profile and persists its forgotten keys")
    func forgetRemovesAndPersists() async throws {
        let initial = HostRecord(
            id: "living-room",
            hostUniqueId: "host-1",
            name: "Living Room",
            address: "192.168.1.10"
        )
        let repository = InMemoryLibraryRepository(LibraryDocument(hosts: [initial]))
        let store = LibraryDocumentStore(repository: repository)
        let roster = HostRoster(store: store, browser: FixedDiscoveryBrowser(hosts: []),
                                poller: FixedHostInfoPoller(infos: [:]))

        _ = try await roster.load()
        let forgotten = try await roster.forget(profileID: "living-room")

        #expect(forgotten.profiles.isEmpty)
        let persisted = try await repository.load()
        #expect(persisted.hosts.isEmpty)
        #expect(persisted.forgottenHostKeys.contains("living-room"))
        #expect(persisted.forgottenHostKeys.contains("host-1"))
        #expect(persisted.forgottenHostKeys.contains("192.168.1.10"))
    }

    @Test("a forgotten host stays gone across a relaunch and a re-discovering refresh")
    func forgottenSurvivesRelaunch() async throws {
        let initial = HostRecord(
            id: "living-room",
            hostUniqueId: "host-1",
            name: "Living Room",
            address: "192.168.1.10"
        )
        let repository = InMemoryLibraryRepository(LibraryDocument(hosts: [initial]))
        let browser = FixedDiscoveryBrowser(hosts: [DiscoveredHost(name: "Living Room", address: "192.168.1.10")])
        let poller = FixedHostInfoPoller(infos: [
            "192.168.1.10": HostInfo(uniqueId: "host-1", hostname: "Living Room", isBusy: false),
        ])
        let now = Date(timeIntervalSince1970: 100)

        // First launch: the user forgets the PC.
        let firstLaunch = HostRoster(store: LibraryDocumentStore(repository: repository),
                                     browser: browser, poller: poller)
        _ = try await firstLaunch.load()
        _ = try await firstLaunch.forget(profileID: "living-room")

        // Relaunch: a brand-new roster loads the same document, then a Bonjour scan re-sees the PC.
        let relaunched = HostRoster(store: LibraryDocumentStore(repository: repository),
                                    browser: browser, poller: poller)
        _ = try await relaunched.load()
        let refreshed = try await relaunched.refresh(now: now)

        #expect(refreshed.profiles.isEmpty)
        #expect(refreshed.availability.isEmpty)
        let persisted = try await repository.load()
        #expect(persisted.hosts.isEmpty)
        #expect(!persisted.forgottenHostKeys.isEmpty)
    }

    @Test("a refresh in flight does not resurrect a host forgotten mid-scan")
    func forgetWinsOverInFlightRefresh() async throws {
        let initial = HostRecord(
            id: "living-room",
            hostUniqueId: "host-1",
            name: "Living Room",
            address: "192.168.1.10"
        )
        let repository = InMemoryLibraryRepository(LibraryDocument(hosts: [initial]))
        let browser = GatedDiscoveryBrowser(hosts: [DiscoveredHost(name: "Living Room", address: "192.168.1.10")])
        let poller = FixedHostInfoPoller(infos: [
            "192.168.1.10": HostInfo(uniqueId: "host-1", hostname: "Living Room", isBusy: false),
        ])
        let roster = HostRoster(store: LibraryDocumentStore(repository: repository), browser: browser, poller: poller)
        _ = try await roster.load()

        // Start a refresh and wait until it is suspended inside the (gated) Bonjour scan.
        let refreshTask = Task { try await roster.refresh(now: Date(timeIntervalSince1970: 100)) }
        await browser.waitUntilEntered()

        // While that scan is in flight, the user forgets the only PC.
        let forgotten = try await roster.forget(profileID: "living-room")
        #expect(forgotten.profiles.isEmpty)

        // Let the in-flight scan complete; the forgotten PC must not be re-added or re-persisted.
        browser.release()
        let refreshed = try await refreshTask.value

        #expect(refreshed.profiles.isEmpty)
        #expect(refreshed.availability.isEmpty)
        #expect((try await repository.load()).hosts.isEmpty)
    }

    @Test("manually re-adding a forgotten host clears its physical forgotten keys")
    func reAddClearsForgottenKeys() async throws {
        let initial = HostRecord(
            id: "living-room",
            hostUniqueId: "host-1",
            name: "Living Room",
            address: "192.168.1.10"
        )
        let repository = InMemoryLibraryRepository(LibraryDocument(hosts: [initial]))
        let browser = FixedDiscoveryBrowser(hosts: [DiscoveredHost(name: "Living Room", address: "192.168.1.10")])
        let poller = FixedHostInfoPoller(infos: [
            "192.168.1.10": HostInfo(uniqueId: "host-1", hostname: "Living Room", isBusy: false),
        ])
        let roster = HostRoster(store: LibraryDocumentStore(repository: repository), browser: browser, poller: poller)
        _ = try await roster.load()

        _ = try await roster.forget(profileID: "living-room")
        // Precondition: forgetting persisted the physical keys so "clearing" them is observable.
        #expect((try await repository.load()).forgottenHostKeys.contains("host-1"))

        let readded = try await roster.addManual("192.168.1.10", now: Date(timeIntervalSince1970: 100))
        #expect(readded?.profiles.contains { $0.hostUniqueId == "host-1" } == true)

        // A subsequent scan keeps the re-added host and no longer suppresses its physical identity.
        let refreshed = try await roster.refresh(now: Date(timeIntervalSince1970: 200))
        #expect(refreshed.profiles.contains { $0.hostUniqueId == "host-1" })
        let persisted = try await repository.load()
        #expect(!persisted.forgottenHostKeys.contains("host-1"))
        #expect(!persisted.forgottenHostKeys.contains("192.168.1.10"))
    }

    @Test("a failed forget is transactional: it leaves the roster and document intact and retryable")
    func failedForgetIsTransactional() async throws {
        let initial = HostRecord(
            id: "living-room",
            hostUniqueId: "host-1",
            name: "Living Room",
            address: "192.168.1.10"
        )
        let repository = FailsOnceRepository(LibraryDocument(hosts: [initial]))
        let store = LibraryDocumentStore(repository: repository)
        let browser = FixedDiscoveryBrowser(hosts: [DiscoveredHost(name: "Living Room", address: "192.168.1.10")])
        let poller = FixedHostInfoPoller(infos: [
            "192.168.1.10": HostInfo(uniqueId: "host-1", hostname: "Living Room", isBusy: false),
        ])
        let roster = HostRoster(store: store, browser: browser, poller: poller)
        _ = try await roster.load()

        // The first save fails, so the forget throws.
        await #expect(throws: RepositorySaveFailure.self) {
            try await roster.forget(profileID: "living-room")
        }

        // The persisted document is untouched: the host is still present and no keys were written.
        let persisted = try await repository.load()
        #expect(persisted.hosts.map(\.id) == ["living-room"])
        #expect(persisted.forgottenHostKeys.isEmpty)

        // The in-memory roster stayed consistent with the document: a refresh still shows the host
        // AND reports its availability (a stale in-memory suppression set would have dropped it from
        // the scan and lost this), and a retry of the forget now succeeds and records the suppression.
        let refreshed = try await roster.refresh(now: Date(timeIntervalSince1970: 100))
        #expect(refreshed.profiles.map(\.id) == ["living-room"])
        #expect(refreshed.availability["living-room"] == .online)
        let forgotten = try await roster.forget(profileID: "living-room")
        #expect(forgotten.profiles.isEmpty)
        let reloaded = try await repository.load()
        #expect(reloaded.hosts.isEmpty)
        #expect(!reloaded.forgottenHostKeys.isEmpty)
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

/// A Bonjour browser whose scan suspends until the test releases it, so a competing `forget`
/// can be interleaved while a `refresh`'s scan is in flight (the resurrection race).
private final class GatedDiscoveryBrowser: HostDiscoveryBrowser, @unchecked Sendable {
    let hosts: [DiscoveredHost]
    private let lock = NSLock()
    private var entered = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    init(hosts: [DiscoveredHost]) {
        self.hosts = hosts
    }

    func scan(forSeconds seconds: Double) async -> [DiscoveredHost] {
        lock.withLock { entered = true }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.withLock { releaseContinuation = continuation }
        }
        return hosts
    }

    /// Suspend until `scan` has been entered, so the test can safely interleave work mid-scan.
    func waitUntilEntered() async {
        while true {
            if lock.withLock({ entered }) { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    /// Release the suspended scan so the in-flight `refresh` can complete.
    func release() {
        let continuation = lock.withLock {
            let cont = releaseContinuation
            releaseContinuation = nil
            return cont
        }
        continuation?.resume()
    }
}

private enum RepositorySaveFailure: Error {
    case save
}

/// A repository whose first `save` throws, to exercise the commit-failure path of roster mutations.
private actor FailsOnceRepository: LibraryRepository {
    private var document: LibraryDocument
    private var shouldFail = true

    init(_ initial: LibraryDocument) { document = initial }

    func load() async throws -> LibraryDocument { document }

    func save(_ document: LibraryDocument) async throws {
        if shouldFail {
            shouldFail = false
            throw RepositorySaveFailure.save
        }
        self.document = document
    }
}
