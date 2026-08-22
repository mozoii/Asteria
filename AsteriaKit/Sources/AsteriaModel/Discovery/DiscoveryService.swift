import Foundation

/// A host seen by a Bonjour scan (name + resolved address); the service tags it as a `.bonjour` sighting.
public struct DiscoveredHost: Sendable, Equatable {
    public var name: String
    public var address: String
    public init(name: String, address: String) {
        self.name = name
        self.address = address
    }
}

/// Raw `/serverinfo` facts from a reachable host; the poller returns nil when the host is unreachable.
public struct HostInfo: Sendable, Equatable {
    public var uniqueId: String
    public var hostname: String
    public var isBusy: Bool
    public var hostSoftware: HostSoftware
    public init(uniqueId: String, hostname: String, isBusy: Bool,
                hostSoftware: HostSoftware = .unknown) {
        self.uniqueId = uniqueId
        self.hostname = hostname
        self.isBusy = isBusy
        self.hostSoftware = hostSoftware
    }
}

/// Bonjour discovery seam — the app wraps NWBrowser; tests inject a fake.
public protocol HostDiscoveryBrowser: Sendable {
    func scan(forSeconds seconds: Double) async -> [DiscoveredHost]
}

/// Per-host `/serverinfo` poll seam — the app wraps HostPoller; tests inject a fake.
public protocol HostInfoPoller: Sendable {
    func fetchInfo(address: String) async -> HostInfo?
}

/// A discovery round's outcome: the reconciled roster and availability for the hosts that were polled.
public struct DiscoveryResult: Sendable, Equatable {
    public var hosts: [HostRecord]
    public var availability: [String: HostAvailability]
    public init(hosts: [HostRecord], availability: [String: HostAvailability]) {
        self.hosts = hosts
        self.availability = availability
    }
}

/// Orchestrates a discovery round over injected browser + poller seams: scan Bonjour, poll every discovered
/// and known address, reconcile into the roster, and report availability — testable without any network.
public struct DiscoveryService: Sendable {
    private let browser: any HostDiscoveryBrowser
    private let poller: any HostInfoPoller

    public init(browser: any HostDiscoveryBrowser, poller: any HostInfoPoller) {
        self.browser = browser
        self.poller = poller
    }

    /// Scan + poll every Bonjour and known-roster address, reconcile, and report availability for each polled host.
    /// `forgotten` holds ids/addresses the user forgot this session; a rediscovered match is dropped, not re-added.
    public func scan(roster: [HostRecord], forgotten: Set<String> = [],
                     scanSeconds: Double = 3, now: Date) async -> DiscoveryResult {
        var targets: [Target] = []
        for host in roster {
            let address = host.manualAddress ?? host.address
            if !targets.contains(where: { $0.address == address }) {
                targets.append(Target(address: address, name: host.name,
                                      source: host.manualAddress != nil ? .manual : .bonjour))
            }
        }
        for host in await browser.scan(forSeconds: scanSeconds) {
            if !targets.contains(where: { $0.address == host.address }) {
                targets.append(Target(address: host.address, name: host.name, source: .bonjour))
            }
        }
        let result = await pollAndReconcile(targets: targets, roster: roster, now: now)
        guard !forgotten.isEmpty else { return result }
        let hosts = result.hosts.filter { !isForgotten($0, forgotten) }
        let ids = Set(hosts.map(\.id))
        return DiscoveryResult(hosts: hosts, availability: result.availability.filter { ids.contains($0.key) })
    }

    private func isForgotten(_ host: HostRecord, _ forgotten: Set<String>) -> Bool {
        forgotten.contains(host.id) || (host.hostUniqueId.map(forgotten.contains) ?? false)
            || forgotten.contains(host.address)
            || (host.manualAddress.map(forgotten.contains) ?? false)
    }

    /// Poll one manually-typed address (normalized), reconcile, and report its availability; nil if unusable.
    public func addManual(rawAddress raw: String, roster: [HostRecord], now: Date) async -> DiscoveryResult? {
        guard let address = ManualHostAddress.normalize(raw) else { return nil }
        return await pollAndReconcile(targets: [Target(address: address, name: address, source: .manual)],
                                      roster: roster, now: now, addConfiguration: true)
    }

    private struct Target: Sendable {
        let address: String
        let name: String
        let source: DiscoverySource
    }

    private func pollAndReconcile(targets: [Target], roster: [HostRecord], now: Date,
                                  addConfiguration: Bool = false) async -> DiscoveryResult {
        let poller = self.poller
        typealias PollResult = (
            index: Int,
            sighting: DiscoverySighting,
            availability: HostAvailability
        )
        var indexedResults: [PollResult] = []
        await withTaskGroup(of: PollResult.self) { group in
            for (index, target) in targets.enumerated() {
                group.addTask {
                    if let info = await poller.fetchInfo(address: target.address) {
                        let sighting = DiscoverySighting(
                            uniqueId: info.uniqueId.isEmpty ? nil : info.uniqueId,
                            name: info.hostname.isEmpty ? target.name : info.hostname,
                            address: target.address, hostSoftware: info.hostSoftware,
                            source: target.source)
                        return (index, sighting, .from(reachable: true, isBusy: info.isBusy))
                    }
                    let sighting = DiscoverySighting(
                        uniqueId: nil,
                        name: target.name,
                        address: target.address,
                        source: target.source
                    )
                    return (index, sighting, .offline)
                }
            }
            for await result in group { indexedResults.append(result) }
        }
        let results = indexedResults.sorted { $0.index < $1.index }.map {
            (sighting: $0.sighting, availability: $0.availability)
        }
        let sightings = results.map(\.sighting)
        var reconciled = RosterReconciler.reconcile(roster: roster, sightings: sightings, now: now)
        if addConfiguration, reconciled.count == roster.count {
            reconciled += RosterReconciler.reconcile(roster: [], sightings: sightings, now: now)
        }
        return DiscoveryResult(hosts: reconciled, availability: availability(for: reconciled, from: results))
    }

    /// Map each polled result to every local configuration for that physical host.
    private func availability(for hosts: [HostRecord],
                              from results: [(sighting: DiscoverySighting, availability: HostAvailability)])
        -> [String: HostAvailability] {
        var map: [String: HostAvailability] = [:]
        for result in results {
            for host in hosts.filter({
                ($0.hostUniqueId != nil && $0.hostUniqueId == result.sighting.uniqueId)
                    || $0.address == result.sighting.address
            }) {
                map[host.id] = result.availability
            }
        }
        return map
    }
}
