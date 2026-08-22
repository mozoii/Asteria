import Testing
@testable import AsteriaModel

@Suite("Settings draft commit")
struct SettingsDraftTests {
    private let caps = StreamCapabilities.unrestricted

    @Test("host draft loads global with the override applied")
    func loadsAppliedOverride() {
        var override = StreamSettingsOverride.empty
        override.frameRate = .fps(120)
        let d = SettingsDraft(isHostScope: true, global: .defaults, override: override, capabilities: caps)
        #expect(d.draft.frameRate == .fps(120))
        #expect(d.draft.resolution == StreamSettings.defaults.resolution)
    }

    @Test("global commit clamps the draft")
    func globalCommitClamps() {
        let caps = StreamCapabilities.make(codecs: [.h264], supportsTenBit: false,
                                           displaySize: nil, displayRefreshHz: nil)
        var d = SettingsDraft(isHostScope: false, global: .defaults, capabilities: caps)
        d.draft.codec = .hevc            // not in caps
        d.draft.bitDepth = .preferTenBit
        let committed = d.committedGlobal()
        #expect(committed.codec == .auto)
        #expect(committed.bitDepth == .eightBit)
    }

    @Test("host commit yields a sparse override of only changed fields")
    func hostCommitSparse() {
        var d = SettingsDraft(isHostScope: true, global: .defaults, capabilities: caps)
        d.draft.frameRate = .fps(120)    // the only change
        let override = d.committedOverride()
        #expect(override.frameRate == .fps(120))
        #expect(override.resolution == nil)
        #expect(override.codec == nil)
        #expect(override.bitrate == nil)
    }

    @Test("an unchanged host draft commits to an empty override")
    func unchangedCommitsEmpty() {
        let d = SettingsDraft(isHostScope: true, global: .defaults, capabilities: caps)
        #expect(d.committedOverride() == .empty)
    }

    @Test("resetToGlobal then commit inherits everything")
    func resetToGlobalInherits() {
        var d = SettingsDraft(isHostScope: true, global: .defaults, capabilities: caps)
        d.draft.frameRate = .fps(120)
        d.resetToGlobal()
        #expect(d.committedOverride() == .empty)
    }

    @Test("clamp before diff: a field clamped back to global drops out of the override")
    func clampBeforeDiffDropsField() {
        // global codec is .auto; a host pins .hevc the caps disallow → clamp → .auto == global → not pinned.
        let caps = StreamCapabilities.make(codecs: [.h264], supportsTenBit: false,
                                           displaySize: nil, displayRefreshHz: nil)
        var d = SettingsDraft(isHostScope: true, global: .defaults, capabilities: caps)
        d.draft.codec = .hevc
        #expect(d.committedOverride().codec == nil)
    }
}
