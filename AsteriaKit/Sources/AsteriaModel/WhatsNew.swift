import Foundation

/// Dev/test override read from the `ASTERIA_SHOW_CHANGES` env var.
public enum WhatsNewOverride: Equatable {
    case none, forceShow, forceHide

    public init(environment: [String: String]) {
        switch environment["ASTERIA_SHOW_CHANGES"] {
        case "1": self = .forceShow
        case "0": self = .forceHide
        default: self = .none
        }
    }
}

/// Pure launch-time decision; the caller owns persisting `lastSeen`.
public enum WhatsNewDecision {
    /// - lastSeen: the marketing version stored at the previous launch, or nil on first install.
    public static func shouldPresent(current: String, lastSeen: String?, override: WhatsNewOverride) -> Bool {
        switch override {
        case .forceShow: return true
        case .forceHide: return false
        case .none: break
        }
        guard let lastSeen else { return false }   // first install: record silently, never show
        return current != lastSeen
    }
}
