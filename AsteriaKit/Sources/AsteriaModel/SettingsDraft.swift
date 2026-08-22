/// Editing model for one settings scope: the effective draft plus its commit (clamp + sparse diff) and
/// stream bit-rate recommendation. The app's SettingsStore is the thin @Observable adapter.
public struct SettingsDraft: Equatable, Sendable {
    public let isHostScope: Bool
    public let global: StreamSettings
    public var draft: StreamSettings
    public let capabilities: StreamCapabilities

    /// Global scope edits the defaults directly; host scope starts from global with the override applied.
    public init(isHostScope: Bool, global: StreamSettings,
                override: StreamSettingsOverride = .empty, capabilities: StreamCapabilities) {
        self.isHostScope = isHostScope
        self.global = global
        self.draft = isHostScope ? global.applying(override) : global
        self.capabilities = capabilities
    }

    /// Discard host customization: inherit the global defaults (commits to an empty override).
    public mutating func resetToGlobal() { draft = global }

    /// Clamped global defaults — the global-scope commit.
    public func committedGlobal() -> StreamSettings { capabilities.clamp(draft) }

    /// Sparse per-host override — the host-scope commit: clamp, then keep only fields differing from global.
    public func committedOverride() -> StreamSettingsOverride {
        StreamSettingsOverride.diff(capabilities.clamp(draft), from: global)
    }
}
