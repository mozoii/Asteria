import Foundation
import Observation
import AsteriaModel

public enum SettingsEditorFailure: Error, Equatable, Sendable {
    case saveFailed(operation: String, detail: String)
    case adaptiveProbeFailed(profileID: String, detail: String)
}

@MainActor
@Observable
public final class SettingsEditor {
    public enum Scope: Equatable, Sendable {
        case global
        case host(HostRecord)

        public var title: String {
            switch self {
            case .global: "Settings"
            case let .host(host): host.displayName
            }
        }

        public var isHost: Bool {
            if case .host = self { true } else { false }
        }
    }

    public let scope: Scope
    public var customizeForHost: Bool
    public var inputPreferences: InputPreferences
    public var overlayPreferences: OverlayPreferences
    public private(set) var hostSupportsAdaptive: Bool?
    public private(set) var lastFailure: SettingsEditorFailure?

    private var model: SettingsDraft
    private let store: LibraryDocumentStore
    private let roster: HostRoster
    private let identities: ClientIdentityVault
    private let onDocumentSaved: @MainActor @Sendable (LibraryDocument) -> Void
    private var adaptiveProbeStarted = false
    private var streamRevision = 0
    private var inputRevision = 0
    private var overlayRevision = 0

    public init(
        scope: Scope,
        document: LibraryDocument,
        capabilities: StreamCapabilities,
        store: LibraryDocumentStore,
        roster: HostRoster,
        identities: ClientIdentityVault,
        onDocumentSaved: @escaping @MainActor @Sendable (LibraryDocument) -> Void = { _ in }
    ) {
        self.scope = scope
        self.store = store
        self.roster = roster
        self.identities = identities
        self.onDocumentSaved = onDocumentSaved
        self.inputPreferences = document.inputPreferences
        self.overlayPreferences = document.overlayPreferences
        switch scope {
        case .global:
            model = SettingsDraft(
                isHostScope: false,
                global: document.globalSettings,
                capabilities: capabilities
            )
            customizeForHost = false
        case let .host(host):
            let profile = document.hosts.first { $0.id == host.id } ?? host
            customizeForHost = profile.settingsOverride != .empty
            model = SettingsDraft(
                isHostScope: true,
                global: document.globalSettings,
                override: profile.settingsOverride,
                capabilities: capabilities
            )
        }
    }

    public var capabilities: StreamCapabilities { model.capabilities }
    public var globalSettings: StreamSettings { model.global }

    public var draft: StreamSettings {
        get { effectiveDraft }
        set { model.draft = newValue }
    }

    public var effectiveDraft: StreamSettings { model.draft }

    public var recommendedBitrateKbps: Int {
        StreamPlan.recommendedKbps(for: effectiveDraft, capabilities: capabilities)
    }

    public func commitStream() async {
        streamRevision += 1
        let revision = streamRevision
        await coalescingDelay()
        guard revision == streamRevision else { return }
        do {
            switch scope {
            case .global:
                let settings = model.committedGlobal()
                let document = try await store.update { $0.globalSettings = settings }
                onDocumentSaved(document)
            case let .host(host):
                if customizeForHost {
                    let override = model.committedOverride()
                    _ = try await roster.updateStreamOverride(override, profileID: host.id)
                } else {
                    if model.draft != model.global { model.resetToGlobal() }
                    _ = try await roster.updateStreamOverride(.empty, profileID: host.id)
                }
                onDocumentSaved(try await store.snapshot())
            }
            lastFailure = nil
        } catch {
            recordFailure(operation: "save stream settings", error: error)
        }
    }

    public func commitInput() async {
        inputRevision += 1
        let revision = inputRevision
        let preferences = inputPreferences
        await coalescingDelay()
        guard revision == inputRevision else { return }
        do {
            let document = try await store.update { $0.inputPreferences = preferences }
            onDocumentSaved(document)
            lastFailure = nil
        } catch {
            recordFailure(operation: "save input preferences", error: error)
        }
    }

    public func commitOverlay() async {
        overlayRevision += 1
        let revision = overlayRevision
        let preferences = overlayPreferences
        await coalescingDelay()
        guard revision == overlayRevision else { return }
        do {
            let document = try await store.update { $0.overlayPreferences = preferences }
            onDocumentSaved(document)
            lastFailure = nil
        } catch {
            recordFailure(operation: "save overlay preferences", error: error)
        }
    }

    public func keyChord(for action: StreamAction) -> KeyChord {
        inputPreferences.keybindings.keyboard[action] ?? .none
    }

    public func gamepadChord(for action: StreamAction) -> GamepadChord {
        inputPreferences.keybindings.gamepad[action] ?? .none
    }

    public func setKeyChord(_ chord: KeyChord?, for action: StreamAction) {
        inputPreferences.keybindings.setKeyboard(chord, for: action)
    }

    public func setGamepadChord(_ chord: GamepadChord?, for action: StreamAction) {
        inputPreferences.keybindings.setGamepad(chord, for: action)
    }

    public func keyboardConflicts(
        _ chord: KeyChord,
        for action: StreamAction
    ) -> [StreamAction] {
        inputPreferences.keybindings.keyboardConflicts(chord, excluding: action)
    }

    public func gamepadConflicts(
        _ chord: GamepadChord,
        for action: StreamAction
    ) -> [StreamAction] {
        inputPreferences.keybindings.gamepadConflicts(chord, excluding: action)
    }

    public func resetKeybindings() {
        inputPreferences.keybindings = .defaults
    }

    public func probeAdaptiveSupportIfNeeded() {
        guard !adaptiveProbeStarted,
              case let .host(host) = scope,
              host.isPaired,
              host.pinnedCertificate != nil else { return }
        adaptiveProbeStarted = true
        Task { [weak self] in
            guard let self else { return }
            do {
                let access = try PairedHostAccess(profile: host, identities: identities)
                hostSupportsAdaptive = await access.supportsRuntimeBitrate()
            } catch {
                lastFailure = .adaptiveProbeFailed(
                    profileID: host.id,
                    detail: error.localizedDescription
                )
            }
        }
    }

    private func coalescingDelay() async {
        try? await Task.sleep(for: .milliseconds(40))
    }

    private func recordFailure(operation: String, error: Error) {
        lastFailure = .saveFailed(operation: operation, detail: error.localizedDescription)
    }
}
