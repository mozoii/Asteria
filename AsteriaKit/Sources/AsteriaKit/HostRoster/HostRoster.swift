import Foundation
import AsteriaModel

public actor HostRoster {
    public struct State: Equatable, Sendable {
        public var profiles: [HostRecord]
        public var availability: [String: HostAvailability]

        public init(
            profiles: [HostRecord] = [],
            availability: [String: HostAvailability] = [:]
        ) {
            self.profiles = profiles
            self.availability = availability
        }
    }

    private let store: LibraryDocumentStore
    private let discovery: DiscoveryService
    private var state = State()
    private var forgottenKeys: Set<String> = []

    public init(
        store: LibraryDocumentStore,
        browser: any HostDiscoveryBrowser,
        poller: any HostInfoPoller
    ) {
        self.store = store
        self.discovery = DiscoveryService(browser: browser, poller: poller)
    }

    public func snapshot() -> State {
        state
    }

    @discardableResult
    public func load() async throws -> State {
        let document = try await store.snapshot()
        state.profiles = document.hosts
        forgottenKeys = Set(document.forgottenHostKeys)
        return state
    }

    @discardableResult
    public func refresh(
        scanSeconds: Double = 3,
        now: Date = Date()
    ) async throws -> State {
        let result = await discovery.scan(
            roster: state.profiles,
            forgotten: forgottenKeys,
            scanSeconds: scanSeconds,
            now: now
        )
        // Re-filter against the current forgotten set at commit time: a forget that ran while this
        // scan was in flight updates `forgottenKeys`, and its stale candidate must not be re-added.
        let candidates = result.hosts.filter { !DiscoveryService.isForgotten($0, in: forgottenKeys) }
        let profiles = profilesFromCandidates(candidates)
        let committed = try await store.update { document in
            document.hosts = profiles
        }
        state.profiles = committed.hosts
        let profileIDs = Set(committed.hosts.map(\.id))
        state.availability = result.availability.filter { profileIDs.contains($0.key) }
        return state
    }

    @discardableResult
    public func addManual(
        _ rawAddress: String,
        now: Date = Date()
    ) async throws -> State? {
        guard let result = await discovery.addManual(
            rawAddress: rawAddress,
            roster: state.profiles,
            now: now
        ) else { return nil }
        let profiles = profilesFromCandidates(result.hosts)
        let previousKeys = forgottenKeys
        for profile in profiles { unforget(profile) }
        let committedKeys = Array(forgottenKeys)
        do {
            let committed = try await store.update { document in
                document.hosts = profiles
                document.forgottenHostKeys = committedKeys
            }
            state.profiles = committed.hosts
            for (id, availability) in result.availability {
                state.availability[id] = availability
            }
            return state
        } catch {
            // A failed persist must leave no in-memory trace: restore the suppression keys we cleared.
            forgottenKeys = previousKeys
            throw error
        }
    }

    @discardableResult
    public func markPaired(_ profile: HostRecord) async throws -> State {
        guard state.profiles.contains(where: { $0.id == profile.id }) else { return state }
        _ = try await updateProfile(profile) { $0 = profile }
        state.availability[profile.id] = .online
        return state
    }

    @discardableResult
    public func rename(profileID: String, to newName: String) async throws -> State {
        try await updateProfile(withID: profileID) { $0.rename(to: newName) }
    }

    @discardableResult
    public func updateStreamOverride(
        _ override: StreamSettingsOverride,
        profileID: String
    ) async throws -> State {
        try await updateProfile(withID: profileID) { $0.settingsOverride = override }
    }

    @discardableResult
    public func forget(profileID: String) async throws -> State {
        guard let profile = state.profiles.first(where: { $0.id == profileID }) else {
            return state
        }
        var profiles = state.profiles
        profiles.removeAll { $0.id == profileID }
        let remainingProfiles = profiles
        let previousKeys = forgottenKeys
        rememberForgotten(profile, remainingProfiles: remainingProfiles)
        let committedKeys = Array(forgottenKeys)
        do {
            let committed = try await store.update { document in
                document.hosts = remainingProfiles
                document.forgottenHostKeys = committedKeys
            }
            state.profiles = committed.hosts
            state.availability[profileID] = nil
            return state
        } catch {
            // A failed persist must leave no in-memory trace: roll back the suppression keys we added.
            forgottenKeys = previousKeys
            throw error
        }
    }

    private func updateProfile(
        _ fallback: HostRecord? = nil,
        withID profileID: String? = nil,
        mutation: @escaping @Sendable (inout HostRecord) -> Void
    ) async throws -> State {
        let id = profileID ?? fallback?.id ?? ""
        guard var profile = state.profiles.first(where: { $0.id == id }) ?? fallback
        else { return state }
        mutation(&profile)
        let updatedProfile = profile
        let committed = try await store.update { $0.upsertHost(updatedProfile) }
        state.profiles = committed.hosts
        return state
    }

    /// Merges candidate profiles into the current roster: updates existing entries in place and
    /// appends new ones, preserving the roster's ordering.
    private func profilesFromCandidates(_ candidates: [HostRecord]) -> [HostRecord] {
        let updates = Dictionary(
            candidates.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let existing = state.profiles.map { updates[$0.id] ?? $0 }
        let existingIDs = Set(existing.map(\.id))
        let additions = candidates.filter { !existingIDs.contains($0.id) }
        return existing + additions
    }

    private func rememberForgotten(_ profile: HostRecord, remainingProfiles: [HostRecord]) {
        forgottenKeys.insert(profile.id)
        let hasSibling = remainingProfiles.contains {
            ($0.hostUniqueId != nil && $0.hostUniqueId == profile.hostUniqueId)
                || $0.address == profile.address
        }
        guard !hasSibling else { return }
        if let uniqueID = profile.hostUniqueId { forgottenKeys.insert(uniqueID) }
        forgottenKeys.insert(profile.address)
        if let manualAddress = profile.manualAddress { forgottenKeys.insert(manualAddress) }
    }

    private func unforget(_ profile: HostRecord) {
        forgottenKeys.remove(profile.id)
        if let uniqueID = profile.hostUniqueId { forgottenKeys.remove(uniqueID) }
        forgottenKeys.remove(profile.address)
        if let manualAddress = profile.manualAddress { forgottenKeys.remove(manualAddress) }
    }
}
