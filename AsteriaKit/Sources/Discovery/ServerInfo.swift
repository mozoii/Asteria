import Foundation

/// Parsed `/serverinfo` response from a GameStream host (Sunshine/Apollo/GFE).
public struct ServerInfo: Sendable, Equatable {
    public var statusCode: Int
    public var hostname: String
    public var appVersion: String
    public var gfeVersion: String?
    /// Fork-specific version field currently emitted by foundation-sunshine.
    public var sunshineVersion: String?
    public var uniqueId: String
    public var httpsPort: UInt16
    public var externalPort: UInt16
    public var mac: String?
    public var localIP: String?
    public var maxLumaPixelsHEVC: Int?
    public var serverCodecModeSupport: Int?
    /// 0 = not paired, 1 = paired.
    public var pairStatus: Int
    /// 0 = no app running.
    public var currentGame: Int
    public var state: String
    /// Apollo per-client permission bitmask; nil on mainline Sunshine/GFE, which never emit `<Permission>`.
    public var permission: UInt32? = nil

    public var isPaired: Bool { pairStatus == 1 }
    public var isBusy: Bool { currentGame != 0 }

    /// Apollo (and its forks) is the only server that emits `<Permission>`; it alone exposes clipboard sync.
    public var isApolloFamily: Bool { permission != nil }
    public var isFoundationSunshine: Bool { sunshineVersion != nil }
}
