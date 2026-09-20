import AsteriaKit

extension SettingsEditor {
    convenience init(
        scope: Scope,
        library: HostListStore,
        capabilities: StreamCapabilities = SettingsEditor.detectCapabilities(),
        identities: ClientIdentityVault = .appKeychain
    ) {
        self.init(
            scope: scope,
            document: library.settingsDocument,
            capabilities: capabilities,
            store: library.documentStore,
            roster: library.roster,
            identities: identities,
            onDocumentSaved: { [weak library] document in
                library?.applySavedDocument(document)
            }
        )
    }

    static func detectCapabilities() -> StreamCapabilities {
        let decoder = DecoderCapabilities.probe(hdrDisplay: DisplayProbe.mainDisplaySupportsEDR)
        // Only families the product negotiates are offered; the rest stay visible but greyed out.
        var codecs: [CodecPreference] = []
        for codec in StreamPlan.negotiableCodecs where codec != .auto {
            if decoderSupports(codec, decoder) { codecs.append(codec) }
        }
        let size = DisplayProbe.mainDisplayPixelSize
        let refresh = DisplayProbe.mainDisplayRefreshHz
        return StreamCapabilities.make(
            codecs: codecs,
            supportsTenBit: decoder.hevcMain10 || decoder.av1Main10,
            supportsHDR: decoder.supportsHDR,
            displaySize: size,
            displayRefreshHz: refresh,
            limitPresetsToDisplay: DisplayProbe.limitsPresetsToPanel
        )
    }

    private static func decoderSupports(_ codec: CodecPreference,
                                        _ decoder: DecoderCapabilities) -> Bool {
        switch codec {
        case .h264: return decoder.h264
        case .hevc: return decoder.hevc
        case .av1: return decoder.av1
        case .auto: return true
        }
    }

    #if DEBUG
    static func preview(
        scope: Scope,
        draft: StreamSettings = .defaults,
        customize: Bool = false,
        inputPreferences: InputPreferences = .defaults,
        overlayPreferences: OverlayPreferences = .defaults,
        capabilities: StreamCapabilities = .unrestricted
    ) -> SettingsEditor {
        let document = LibraryDocument(
            globalSettings: draft,
            inputPreferences: inputPreferences,
            overlayPreferences: overlayPreferences
        )
        let documentStore = LibraryDocumentStore(repository: InMemoryLibraryRepository(document))
        let roster = HostRoster(
            store: documentStore,
            browser: PreviewDiscoveryBrowser(),
            poller: PreviewHostInfoPoller()
        )
        let editor = SettingsEditor(
            scope: scope,
            document: document,
            capabilities: capabilities,
            store: documentStore,
            roster: roster,
            identities: ClientIdentityVault(secretStore: InMemorySecretStore())
        )
        editor.draft = draft
        editor.customizeForHost = customize
        return editor
    }
    #endif
}

#if DEBUG
private struct PreviewDiscoveryBrowser: HostDiscoveryBrowser {
    func scan(forSeconds: Double) async -> [DiscoveredHost] { [] }
}

private struct PreviewHostInfoPoller: HostInfoPoller {
    func fetchInfo(address: String) async -> HostInfo? { nil }
}
#endif
