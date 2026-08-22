import Foundation

/// Where a host sighting came from.
public enum DiscoverySource: String, Codable, Sendable, Equatable {
    case bonjour, manual
}

/// Live reachability of a host, derived from a `/serverinfo` poll. `unknown` is the pre-poll default.
public enum HostAvailability: String, Codable, Sendable, Equatable {
    case online, offline, busy, unknown

    public static func from(reachable: Bool, isBusy: Bool) -> HostAvailability {
        guard reachable else { return .offline }
        return isBusy ? .busy : .online
    }
}

/// A single observation of a host from a scan or poll.
public struct DiscoverySighting: Sendable, Equatable {
    public var uniqueId: String?
    public var name: String
    public var address: String
    public var hostSoftware: HostSoftware
    public var source: DiscoverySource

    public init(uniqueId: String? = nil, name: String, address: String,
                hostSoftware: HostSoftware = .unknown, source: DiscoverySource) {
        self.uniqueId = uniqueId
        self.name = name
        self.address = address
        self.hostSoftware = hostSoftware
        self.source = source
    }
}

/// Normalizes a user-typed host address; nil when nothing usable remains.
public enum ManualHostAddress {
    public static func normalize(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["https://", "http://"] where s.lowercased().hasPrefix(prefix) {
            s = String(s.dropFirst(prefix.count))
        }
        while s.hasSuffix("/") { s.removeLast() }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }
}

/// Folds sightings into the roster while keeping local client configurations distinct.
public enum RosterReconciler {
    public static func reconcile(roster: [HostRecord], sightings: [DiscoverySighting], now: Date,
                                 makeID: () -> String = { UUID().uuidString }) -> [HostRecord] {
        var result = roster
        for sighting in sightings {
            let indices = matchIndices(in: result, for: sighting)
            if !indices.isEmpty {
                for index in indices {
                    var host = result[index]
                    if let uid = sighting.uniqueId { host.hostUniqueId = uid }
                    host.address = sighting.address
                    if !sighting.name.isEmpty { host.name = sighting.name }
                    if sighting.hostSoftware != .unknown {
                        host.hostSoftware = sighting.hostSoftware
                    }
                    if sighting.source == .manual { host.manualAddress = sighting.address }
                    host.lastSeen = now
                    result[index] = host
                }
            } else {
                result.append(HostRecord(
                    id: makeID(), hostUniqueId: sighting.uniqueId,
                    hostSoftware: sighting.hostSoftware,
                    name: sighting.name.isEmpty ? sighting.address : sighting.name,
                    address: sighting.address,
                    manualAddress: sighting.source == .manual ? sighting.address : nil,
                    isPaired: false,
                    lastSeen: now))
            }
        }
        return result
    }

    private static func matchIndices(in roster: [HostRecord], for sighting: DiscoverySighting) -> [Int] {
        if let uid = sighting.uniqueId {
            let matches = roster.indices.filter { roster[$0].hostUniqueId == uid }
            if !matches.isEmpty { return matches }
        }
        return roster.indices.filter {
            roster[$0].address == sighting.address || roster[$0].manualAddress == sighting.address
        }
    }
}
