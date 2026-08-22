import Testing
@testable import AsteriaModel

@Suite("Stream plan")
struct StreamPlanTests {
    @Test("Asteria quality targets")
    func qualityTargets() {
        #expect(recommendation(width: 3_840, height: 2_160, fps: 60) == 125_000)
        #expect(recommendation(width: 3_840, height: 2_160, fps: 240) == 250_000)
        #expect(recommendation(width: 3_840, height: 2_160, fps: 240, tenBit: true) == 305_000)
    }

    @Test("Pixel count scales continuously")
    func continuousSpatialScaling() {
        #expect(recommendation(width: 1_920, height: 1_080, fps: 60) == 31_250)
        #expect(recommendation(width: 1_600, height: 900, fps: 60) == 21_701)
        #expect(recommendation(width: 1_280, height: 720, fps: 60) == 13_889)
    }

    @Test("Frame-rate scaling is proportional through 60 fps")
    func standardFrameRateScaling() {
        #expect(recommendation(width: 3_840, height: 2_160, fps: 30) == 62_500)
        #expect(recommendation(width: 3_840, height: 2_160, fps: 60) == 125_000)
    }

    @Test("Frame-rate scaling tapers and caps at 240 fps")
    func highFrameRateScaling() {
        #expect(recommendation(width: 3_840, height: 2_160, fps: 120) == 166_667)
        #expect(recommendation(width: 3_840, height: 2_160, fps: 240) == 250_000)
        #expect(recommendation(width: 3_840, height: 2_160, fps: 360) == 250_000)
    }

    @Test("Unknown display capabilities use 1080p60")
    func fallback() {
        var settings = StreamSettings.defaults
        settings.resolution = .matchDisplay
        settings.frameRate = .matchDisplay
        #expect(StreamPlan.recommendedKbps(for: settings, capabilities: .unrestricted) == 31_250)
    }

    @Test("Codec choice does not change the recommendation")
    func codecNeutrality() {
        var h264 = StreamSettings.defaults
        h264.resolution = .uhd4K
        h264.codec = .h264
        var av1 = h264
        av1.codec = .av1
        let capabilities = StreamCapabilities.unrestricted
        #expect(StreamPlan.recommendedKbps(for: h264, capabilities: capabilities)
                == StreamPlan.recommendedKbps(for: av1, capabilities: capabilities))
    }

    @Test("Unsupported 10-bit preference does not receive the uplift")
    func capabilityClamping() {
        var settings = StreamSettings.defaults
        settings.resolution = .uhd4K
        settings.bitDepth = .preferTenBit
        var capabilities = StreamCapabilities.unrestricted
        capabilities.supportsTenBit = false
        #expect(StreamPlan.recommendedKbps(for: settings, capabilities: capabilities) == 125_000)
    }

    @Test("resolve merges the per-host override and clamps")
    func resolveMergesOverrideAndClamps() {
        var global = StreamSettings.defaults
        global.resolution = .hd1080
        var override = StreamSettingsOverride.empty
        override.codec = .av1
        let caps = StreamCapabilities.make(codecs: [.h264], supportsTenBit: false,
                                           displaySize: nil, displayRefreshHz: nil)
        let plan = StreamPlan.resolve(global: global, override: override, capabilities: caps)
        #expect(plan.settings.codec == .auto)          // .av1 unsupported → clamped to .auto
        #expect(plan.settings.resolution == .hd1080)   // global value survives
        #expect(plan.size == PixelSize(width: 1920, height: 1080))
        #expect(plan.fps == 60)
        #expect(plan.bitrateKbps == plan.settings.bitrate.resolvedKbps(
            recommendedKbps: StreamPlan.recommendedKbps(for: plan.settings, capabilities: caps)))
    }

    @Test("resolve forces 10-bit and HEVC when HDR is on")
    func resolveAppliesHDRInvariant() {
        var settings = StreamSettings.defaults
        settings.hdr = true
        settings.codec = .h264
        settings.bitDepth = .eightBit
        let plan = StreamPlan.resolve(settings: settings, capabilities: .unrestricted)
        #expect(plan.settings.bitDepth == .preferTenBit)
        #expect(plan.settings.codec == .hevc)
        #expect(plan.preferTenBit)
    }

    @Test("negotiableCodecs drives the picker and excludes AV1")
    func negotiableCodecsPolicy() {
        #expect(StreamPlan.negotiableCodecs.contains(.h264))
        #expect(StreamPlan.negotiableCodecs.contains(.hevc))
        #expect(!StreamPlan.negotiableCodecs.contains(.av1))
        let caps = StreamCapabilities.make(
            codecs: StreamPlan.negotiableCodecs, supportsTenBit: true,
            displaySize: nil, displayRefreshHz: nil)
        #expect(!caps.allows(codec: .av1))
        #expect(caps.allowsCodec(.hevc, whenHDR: true))
        #expect(!caps.allowsCodec(.h264, whenHDR: true))
        #expect(caps.allowsCodec(.auto, whenHDR: true))
    }

    @Test("first-run recommendation: native resolution, 60 fps, 8-bit, auto-curve bitrate")
    func firstRunRecommendation() {
        var global = StreamSettings.defaults
        global.resolution = .hd720
        global.bitDepth = .preferTenBit
        let caps = StreamCapabilities.make(
            codecs: [.h264, .hevc], supportsTenBit: true,
            displaySize: PixelSize(width: 2560, height: 1440), displayRefreshHz: 120)
        let settings = StreamPlan.firstRunRecommendation(global: global, capabilities: caps)
        #expect(settings.resolution == .matchDisplay)
        #expect(settings.frameRate == .fps(60))
        #expect(settings.codec == .hevc)   // newest negotiable codec
        #expect(settings.bitDepth == .eightBit)
        #expect(settings.bitrate == .manual(kbps: StreamPlan.recommendedKbps(
            for: settings, capabilities: caps)))
    }

    @Test("first-run recommendation falls back to 1080p without a display")
    func firstRunRecommendationWithoutDisplay() {
        let caps = StreamCapabilities.make(
            codecs: [.h264], supportsTenBit: false,
            displaySize: nil, displayRefreshHz: nil)
        let settings = StreamPlan.firstRunRecommendation(global: .defaults, capabilities: caps)
        #expect(settings.resolution == .hd1080)
        #expect(settings.codec == .h264)
    }

    private func recommendation(
        width: Int,
        height: Int,
        fps: Int,
        tenBit: Bool = false
    ) -> Int {
        var settings = StreamSettings.defaults
        settings.resolution = .custom(width: width, height: height)
        settings.frameRate = .fps(fps)
        settings.bitDepth = tenBit ? .preferTenBit : .eightBit
        return StreamPlan.recommendedKbps(for: settings, capabilities: .unrestricted)
    }
}
