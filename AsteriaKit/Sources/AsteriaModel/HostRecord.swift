import Foundation
import AsteriaCore

/// Sunshine-family implementation detected from protocol fields the host advertises.
public enum HostSoftware: String, Codable, Equatable, Sendable {
    case sunshineCompatible
    case apolloFamily
    case foundationSunshine
    case unknown

    public var displayName: String {
        switch self {
        case .sunshineCompatible: "Sunshine-compatible"
        case .apolloFamily: "Apollo / Vibepollo"
        case .foundationSunshine: "foundation-sunshine"
        case .unknown: "Unknown host"
        }
    }
}

/// A known host in the roster: discovered or manually added, paired or not, with its per-host settings.
public struct HostRecord: Codable, Equatable, Sendable, Identifiable {
    /// Stable local configuration id. Multiple configurations may target the same physical host.
    public var id: String
    /// Host installation identity from `serverinfo.uniqueid`; shared by configurations for one host.
    public var hostUniqueId: String?
    /// Full SHA-256 digest of this configuration's client certificate DER; nil until paired.
    public var clientFingerprint: ClientFingerprint?
    public var hostSoftware: HostSoftware
    /// Serverinfo-derived hostname; refreshed on every discovery poll, so never store a user edit here.
    public var name: String
    /// User-chosen display name; when set it overrides `name` and survives discovery refreshes.
    public var customName: String?
    public var address: String
    /// User-entered address, kept even when Bonjour later reports a different name.
    public var manualAddress: String?
    public var isPaired: Bool
    /// Pinned server certificate (DER) for this host; nil until paired.
    public var pinnedCertificate: Data?
    public var lastSeen: Date?
    public var settingsOverride: StreamSettingsOverride

    public init(id: String, hostUniqueId: String? = nil, clientFingerprint: ClientFingerprint? = nil,
                hostSoftware: HostSoftware = .unknown, name: String, customName: String? = nil,
                address: String, manualAddress: String? = nil,
                isPaired: Bool = false, pinnedCertificate: Data? = nil, lastSeen: Date? = nil,
                settingsOverride: StreamSettingsOverride = .empty) {
        self.id = id
        self.hostUniqueId = hostUniqueId
        self.clientFingerprint = clientFingerprint
        self.hostSoftware = hostSoftware
        self.name = name
        self.customName = customName
        self.address = address
        self.manualAddress = manualAddress
        self.isPaired = isPaired
        self.pinnedCertificate = pinnedCertificate
        self.lastSeen = lastSeen
        self.settingsOverride = settingsOverride
    }

    private enum CodingKeys: String, CodingKey {
        case id, hostUniqueId, clientFingerprint, hostSoftware, name, customName, address
        case manualAddress, isPaired, pinnedCertificate, lastSeen, settingsOverride
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        hostUniqueId = try container.decodeIfPresent(String.self, forKey: .hostUniqueId)
        clientFingerprint = try container.decodeIfPresent(
            ClientFingerprint.self, forKey: .clientFingerprint)
        hostSoftware = try container.decodeIfPresent(
            HostSoftware.self, forKey: .hostSoftware) ?? .unknown
        name = try container.decode(String.self, forKey: .name)
        customName = try container.decodeIfPresent(String.self, forKey: .customName)
        address = try container.decode(String.self, forKey: .address)
        manualAddress = try container.decodeIfPresent(String.self, forKey: .manualAddress)
        isPaired = try container.decode(Bool.self, forKey: .isPaired)
        pinnedCertificate = try container.decodeIfPresent(Data.self, forKey: .pinnedCertificate)
        lastSeen = try container.decodeIfPresent(Date.self, forKey: .lastSeen)
        settingsOverride = try container.decodeIfPresent(
            StreamSettingsOverride.self, forKey: .settingsOverride) ?? .empty
    }

    public var displayName: String {
        if let custom = customName, !custom.isEmpty { return custom }
        return name
    }

    /// Blank or whitespace input clears the override.
    public mutating func rename(to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        customName = trimmed.isEmpty ? nil : trimmed
    }

    /// Record a successful pairing: flag paired and pin the host's server certificate.
    public mutating func markPaired(pinnedCertificate: Data, clientFingerprint: ClientFingerprint) {
        isPaired = true
        self.pinnedCertificate = pinnedCertificate
        self.clientFingerprint = clientFingerprint
    }
}
