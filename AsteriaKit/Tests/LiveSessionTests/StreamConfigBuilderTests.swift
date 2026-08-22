import Testing
import GameStreamProtocol
import AsteriaModel
@testable import LiveSession

@Suite("StreamConfigBuilder")
struct StreamConfigBuilderTests {
    private func caps(displaySize: PixelSize? = nil, displayRefreshHz: Int? = nil,
                      supportsTenBit: Bool = true, supportsHDR: Bool = false,
                      codecs: [CodecPreference] = [.h264, .hevc]) -> StreamCapabilities {
        StreamCapabilities.make(codecs: codecs, supportsTenBit: supportsTenBit, supportsHDR: supportsHDR,
                                displaySize: displaySize, displayRefreshHz: displayRefreshHz)
    }

    @Test("preset resolution, fps, and manual bitrate flow through verbatim")
    func presetFlowThrough() {
        var s = StreamSettings.defaults
        s.resolution = .qhd1440
        s.frameRate = .fps120
        s.bitrate = .manual(kbps: 35_000)
        s.audio = .surround51
        let plan = StreamConfigBuilder.plan(appId: "42", settings: s, capabilities: caps())
        #expect(plan.configuration.appId == "42")
        #expect(plan.configuration.width == 2560)
        #expect(plan.configuration.height == 1440)
        #expect(plan.configuration.fps == 120)
        #expect(plan.configuration.bitrateKbps == 35_000)
        #expect(plan.configuration.audio == .surround51)
    }

    @Test("codec preference flows through the plan, clamped to caps")
    func codecFlowsThrough() {
        var s = StreamSettings.defaults
        s.codec = .hevc
        #expect(StreamConfigBuilder.plan(appId: "1", settings: s, capabilities: caps()).codec == .hevc)
        s.codec = .av1   // caps offers only h264/hevc → clamped to auto
        #expect(StreamConfigBuilder.plan(appId: "1", settings: s, capabilities: caps()).codec == .auto)
    }

    @Test("auto bitrate resolves from the chosen resolution and fps")
    func autoBitrate() {
        var s = StreamSettings.defaults
        s.resolution = .hd1080
        s.frameRate = .fps60
        s.bitrate = .auto
        let plan = StreamConfigBuilder.plan(appId: "1", settings: s, capabilities: caps())
        #expect(plan.configuration.bitrateKbps == 31_250)
    }

    @Test("matchDisplay uses the live display size and refresh")
    func matchDisplay() {
        var s = StreamSettings.defaults
        s.resolution = .matchDisplay
        s.frameRate = .matchDisplay
        let plan = StreamConfigBuilder.plan(
            appId: "1", settings: s,
            capabilities: caps(displaySize: PixelSize(width: 3456, height: 2234), displayRefreshHz: 120))
        #expect(plan.configuration.width == 3456)
        #expect(plan.configuration.height == 2234)
        #expect(plan.configuration.fps == 120)
    }

    @Test("matchDisplay falls back to 1080p60 when the display is unknown")
    func matchDisplayFallback() {
        var s = StreamSettings.defaults
        s.resolution = .matchDisplay
        s.frameRate = .matchDisplay
        let plan = StreamConfigBuilder.plan(appId: "1", settings: s, capabilities: caps())
        #expect(plan.configuration.width == 1920)
        #expect(plan.configuration.height == 1080)
        #expect(plan.configuration.fps == 60)
    }

    @Test("10-bit is requested only when the decoder supports it")
    func tenBitClamp() {
        var s = StreamSettings.defaults
        s.bitDepth = .preferTenBit
        #expect(StreamConfigBuilder.plan(appId: "1", settings: s, capabilities: caps(supportsTenBit: true)).preferTenBit)
        #expect(!StreamConfigBuilder.plan(appId: "1", settings: s, capabilities: caps(supportsTenBit: false)).preferTenBit)
    }

    @Test("HDR flows to the configuration and forces 10-bit when supported")
    func hdrRequested() {
        var s = StreamSettings.defaults
        s.hdr = true
        s.bitDepth = .eightBit   // HDR overrides the bit-depth choice
        let plan = StreamConfigBuilder.plan(appId: "1", settings: s, capabilities: caps(supportsHDR: true))
        #expect(plan.configuration.hdr)
        #expect(plan.preferTenBit)
    }

    @Test("HDR is dropped when the display/decoder can't do it")
    func hdrClampedAway() {
        var s = StreamSettings.defaults
        s.hdr = true
        let plan = StreamConfigBuilder.plan(appId: "1", settings: s, capabilities: caps(supportsHDR: false))
        #expect(!plan.configuration.hdr)
    }

    @Test("10-bit SDR still requests no HDR")
    func tenBitSdrNoHdr() {
        var s = StreamSettings.defaults
        s.bitDepth = .preferTenBit
        let plan = StreamConfigBuilder.plan(appId: "1", settings: s, capabilities: caps())
        #expect(!plan.configuration.hdr)
        #expect(plan.preferTenBit)
    }

    @Test("playAudioOnHost flows to the session configuration; default off")
    func playAudioOnHostFlow() {
        #expect(!StreamConfigBuilder.plan(appId: "1", settings: .defaults, capabilities: caps()).configuration.playAudioOnHost)
        var s = StreamSettings.defaults
        s.playAudioOnHost = true
        #expect(StreamConfigBuilder.plan(appId: "1", settings: s, capabilities: caps()).configuration.playAudioOnHost)
    }
}
