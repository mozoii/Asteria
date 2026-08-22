import Foundation
import Testing
@testable import AsteriaModel

@Suite("Stream settings merge & resolution")
struct StreamSettingsTests {
    @Test("Empty override leaves global settings unchanged")
    func emptyOverride() {
        let global = StreamSettings.defaults
        #expect(global.applying(.empty) == global)
    }

    @Test("windowMode override wins; defaults to windowed fullscreen")
    func windowModeOverride() {
        #expect(StreamSettings.defaults.windowMode == .windowedFullscreen)
        var override = StreamSettingsOverride.empty
        override.windowMode = .windowed
        #expect(StreamSettings.defaults.applying(override).windowMode == .windowed)
    }

    @Test("hideTitleBarInWindowedMode persists through overrides and defaults to off")
    func hideTitleBarInWindowedModeOverride() {
        #expect(StreamSettings.defaults.hideTitleBarInWindowedMode == false)
        var draft = StreamSettings.defaults
        draft.hideTitleBarInWindowedMode = true
        let override = StreamSettingsOverride.diff(draft, from: .defaults)
        #expect(override.hideTitleBarInWindowedMode == true)
        #expect(StreamSettings.defaults.applying(override).hideTitleBarInWindowedMode)
    }

    @Test("Settings written before hideTitleBarInWindowedMode decode with the default")
    func decodesPreHideTitleBarDocument() throws {
        let data = try JSONEncoder().encode(StreamSettings.defaults)
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "hideTitleBarInWindowedMode")
        let stripped = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(StreamSettings.self, from: stripped)
        #expect(decoded.hideTitleBarInWindowedMode == false)
    }

    @Test("closeAppOnDisconnect override wins; defaults to off")
    func closeAppOnDisconnectOverride() {
        #expect(StreamSettings.defaults.closeAppOnDisconnect == false)
        var override = StreamSettingsOverride.empty
        override.closeAppOnDisconnect = true
        #expect(StreamSettings.defaults.applying(override).closeAppOnDisconnect == true)
    }


    @Test("Settings written before closeAppOnDisconnect existed decode with the default")
    func decodesPreCloseAppDocument() throws {
        let data = try JSONEncoder().encode(StreamSettings.defaults)
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "closeAppOnDisconnect")
        let stripped = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(StreamSettings.self, from: stripped)
        #expect(decoded.closeAppOnDisconnect == false)
    }

    @Test("hdr override wins; defaults to off")
    func hdrOverride() {
        #expect(StreamSettings.defaults.hdr == false)
        var override = StreamSettingsOverride.empty
        override.hdr = true
        #expect(StreamSettings.defaults.applying(override).hdr == true)
    }

    @Test("Settings written before hdr existed decode with the default")
    func decodesPreHdrDocument() throws {
        let data = try JSONEncoder().encode(StreamSettings.defaults)
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "hdr")
        let stripped = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(StreamSettings.self, from: stripped)
        #expect(decoded.hdr == false)
    }

    @Test("hdr survives a diff/apply round-trip")
    func hdrRoundTrips() {
        var draft = StreamSettings.defaults
        draft.hdr = true
        let override = StreamSettingsOverride.diff(draft, from: .defaults)
        #expect(override.hdr == true)
        #expect(StreamSettings.defaults.applying(override).hdr == true)
    }

    @Test("syncClipboard override wins; defaults to off")
    func syncClipboardOverride() {
        #expect(StreamSettings.defaults.syncClipboard == false)
        var override = StreamSettingsOverride.empty
        override.syncClipboard = true
        #expect(StreamSettings.defaults.applying(override).syncClipboard == true)
    }

    @Test("Settings written before syncClipboard existed decode with the default")
    func decodesPreSyncClipboardDocument() throws {
        let data = try JSONEncoder().encode(StreamSettings.defaults)
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "syncClipboard")
        let stripped = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(StreamSettings.self, from: stripped)
        #expect(decoded.syncClipboard == false)
    }

    @Test("playAudioOnHost override wins; defaults to off")
    func playAudioOnHostOverride() {
        #expect(StreamSettings.defaults.playAudioOnHost == false)
        var override = StreamSettingsOverride.empty
        override.playAudioOnHost = true
        #expect(StreamSettings.defaults.applying(override).playAudioOnHost == true)
    }

    @Test("Settings written before playAudioOnHost existed decode with the default")
    func decodesPrePlayAudioOnHostDocument() throws {
        let data = try JSONEncoder().encode(StreamSettings.defaults)
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "playAudioOnHost")
        let stripped = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(StreamSettings.self, from: stripped)
        #expect(decoded.playAudioOnHost == false)
    }

    @Test("playAudioOnHost diff captures only changed values")
    func playAudioOnHostDiff() {
        #expect(StreamSettingsOverride.diff(StreamSettings.defaults, from: .defaults).playAudioOnHost == nil)
        var draft = StreamSettings.defaults
        draft.playAudioOnHost = true
        #expect(StreamSettingsOverride.diff(draft, from: .defaults).playAudioOnHost == true)
    }

    @Test("Settings written before windowMode existed decode with the default")
    func decodesPreWindowModeDocument() throws {
        var settings = StreamSettings.defaults
        settings.resolution = .qhd1440
        let data = try JSONEncoder().encode(settings)
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "windowMode")
        let stripped = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(StreamSettings.self, from: stripped)
        #expect(decoded.windowMode == .windowedFullscreen)
        #expect(decoded.resolution == .qhd1440)
    }

    @Test("Override wins field-by-field where set")
    func partialOverride() {
        var override = StreamSettingsOverride.empty
        override.frameRate = .fps(120)
        override.bitrate = .manual(kbps: 50_000)
        let merged = StreamSettings.defaults.applying(override)
        #expect(merged.frameRate == .fps(120))
        #expect(merged.bitrate == .manual(kbps: 50_000))
        #expect(merged.resolution == StreamSettings.defaults.resolution)
        #expect(merged.codec == StreamSettings.defaults.codec)
    }

    @Test("Preset resolution reports its pixel dimensions")
    func presetDimensions() {
        #expect(VideoResolution.hd1080.dimensions(matchingDisplay: nil) == PixelSize(width: 1920, height: 1080))
        #expect(VideoResolution.uhd4K.dimensions(matchingDisplay: nil) == PixelSize(width: 3840, height: 2160))
    }

    @Test("Match-display resolution resolves against the supplied display")
    func matchDisplay() {
        let display = PixelSize(width: 3456, height: 2234)
        #expect(VideoResolution.matchDisplay.dimensions(matchingDisplay: display) == display)
        #expect(VideoResolution.matchDisplay.dimensions(matchingDisplay: nil) == nil)
    }

    @Test("Auto bit rate resolves from the formula (incl. 10-bit); manual is passed through")
    func bitrateResolution() {
        #expect(BitrateSetting.auto.resolvedKbps(recommendedKbps: 31_250) == 31_250)
        #expect(BitrateSetting.auto.resolvedKbps(recommendedKbps: 38_125) == 38_125)
        // Manual ignores resolution/fps/bit depth.
        #expect(BitrateSetting.manual(kbps: 12_345).resolvedKbps(recommendedKbps: 38_125)
                == 12_345)
    }

    @Test("Adaptive starts from the auto value and reports itself as adaptive")
    func adaptiveResolution() {
        #expect(BitrateSetting.adaptive.resolvedKbps(recommendedKbps: 31_250) == 31_250)
        #expect(BitrateSetting.adaptive.isAdaptive)
        #expect(!BitrateSetting.auto.isAdaptive)
    }

    @Test("adaptiveMode defaults to Prefer Quality and survives absence in old documents")
    func adaptiveModeDefault() throws {
        #expect(StreamSettings.defaults.adaptiveMode == .preferQuality)
        let data = try JSONEncoder().encode(StreamSettings.defaults)
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "adaptiveMode")
        let stripped = try JSONSerialization.data(withJSONObject: object)
        #expect(try JSONDecoder().decode(StreamSettings.self, from: stripped).adaptiveMode == .preferQuality)
    }

    @Test("adaptiveMode round-trips through diff/apply and is captured sparsely")
    func adaptiveModeOverride() {
        var draft = StreamSettings.defaults
        draft.bitrate = .adaptive
        draft.adaptiveMode = .preferLatency
        let override = StreamSettingsOverride.diff(draft, from: .defaults)
        #expect(override.adaptiveMode == .preferLatency)
        #expect(StreamSettings.defaults.applying(override) == draft)
    }

    @Test("diff then apply round-trips to the draft")
    func diffRoundTrips() {
        var draft = StreamSettings.defaults
        draft.resolution = .qhd1440
        draft.codec = .hevc
        draft.enableMetalFX = true
        let override = StreamSettingsOverride.diff(draft, from: .defaults)
        #expect(StreamSettings.defaults.applying(override) == draft)
    }

    @Test("diff of equal settings is empty; one change sets only that field")
    func diffSparsity() {
        #expect(StreamSettingsOverride.diff(.defaults, from: .defaults) == .empty)
        var draft = StreamSettings.defaults
        draft.audio = .surround71
        let override = StreamSettingsOverride.diff(draft, from: .defaults)
        #expect(override.audio == .surround71)
        #expect(override.resolution == nil)
        #expect(override.frameRate == nil)
    }

    @Test("custom-entry constructors clamp to sane minimums")
    func customEntryClamps() {
        #expect(VideoResolution.custom(clampingWidth: 0, height: -5) == .custom(width: 1, height: 1))
        #expect(FrameRate.fps(clamping: 0) == .fps(1))
        #expect(BitrateSetting.manual(clampingMbps: 0.1) == .manual(kbps: 500))
        #expect(BitrateSetting.manual(clampingMbps: 50) == .manual(kbps: 50_000))
    }
}
