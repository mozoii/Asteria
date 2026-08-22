import Foundation
import Testing
@testable import AsteriaModel

@Suite("Stream capabilities gating")
struct StreamCapabilitiesTests {
    @Test("Full preset ladder includes 4K and 240 fps regardless of display")
    func fullLadderRegardlessOfDisplay() {
        let caps = StreamCapabilities.make(
            codecs: [.h264, .hevc], supportsTenBit: true,
            displaySize: PixelSize(width: 1920, height: 1080), displayRefreshHz: 60)
        #expect(caps.resolutionPresets == StreamCapabilities.allResolutionPresets)
        #expect(caps.resolutionPresets.contains(PixelSize(width: 3840, height: 2160)))
        #expect(caps.frameRatePresets == StreamCapabilities.allFrameRatePresets)
        #expect(caps.frameRatePresets.contains(240))
    }

    @Test("Display size and refresh are still retained for Match/auto-bitrate")
    func retainsDisplayInfo() {
        let caps = StreamCapabilities.make(codecs: [.h264], supportsTenBit: false,
                                           displaySize: PixelSize(width: 2560, height: 1440), displayRefreshHz: 120)
        #expect(caps.displaySize == PixelSize(width: 2560, height: 1440))
        #expect(caps.displayRefreshHz == 120)
    }

    @Test("clamp drops an unsupported codec to auto")
    func clampCodec() {
        let caps = StreamCapabilities(codecs: [.h264], supportsTenBit: true,
                                      resolutionPresets: [], frameRatePresets: [])
        var settings = StreamSettings.defaults
        settings.codec = .av1
        #expect(caps.clamp(settings).codec == .auto)
        settings.codec = .h264
        #expect(caps.clamp(settings).codec == .h264)
    }

    @Test("clamp drops 10-bit when the decoder can't do it")
    func clampTenBit() {
        let caps = StreamCapabilities(codecs: [.hevc], supportsTenBit: false,
                                      resolutionPresets: [], frameRatePresets: [])
        var settings = StreamSettings.defaults
        settings.bitDepth = .preferTenBit
        #expect(caps.clamp(settings).bitDepth == .eightBit)
    }

    @Test("clamp drops HDR when the display/decoder can't do it")
    func clampHdrUnsupported() {
        let caps = StreamCapabilities(codecs: [.hevc], supportsTenBit: true, supportsHDR: false,
                                      resolutionPresets: [], frameRatePresets: [])
        var settings = StreamSettings.defaults
        settings.hdr = true
        #expect(caps.clamp(settings).hdr == false)
    }

    @Test("clamp forces 10-bit when HDR is on")
    func clampHdrForcesTenBit() {
        let caps = StreamCapabilities(codecs: [.hevc], supportsTenBit: true, supportsHDR: true,
                                      resolutionPresets: [], frameRatePresets: [])
        var settings = StreamSettings.defaults
        settings.hdr = true
        settings.bitDepth = .eightBit
        let clamped = caps.clamp(settings)
        #expect(clamped.hdr == true)
        #expect(clamped.bitDepth == .preferTenBit)
    }

    @Test("clamp forces a non-auto codec to HEVC when HDR is on")
    func clampHdrForcesHevc() {
        let caps = StreamCapabilities.unrestricted
        var settings = StreamSettings.defaults
        settings.hdr = true
        settings.codec = .h264
        #expect(caps.clamp(settings).codec == .hevc)
        settings.codec = .av1
        #expect(caps.clamp(settings).codec == .hevc)
    }

    @Test("clamp leaves auto codec untouched when HDR is on")
    func clampHdrKeepsAuto() {
        let caps = StreamCapabilities.unrestricted
        var settings = StreamSettings.defaults
        settings.hdr = true
        settings.codec = .auto
        #expect(caps.clamp(settings).codec == .auto)
    }

    @Test("unrestricted caps advertise HDR support")
    func unrestrictedSupportsHDR() {
        #expect(StreamCapabilities.unrestricted.supportsHDR == true)
    }

    @Test("clamp leaves supported settings untouched")
    func clampNoop() {
        let caps = StreamCapabilities.unrestricted
        var settings = StreamSettings.defaults
        settings.codec = .hevc
        settings.bitDepth = .preferTenBit
        #expect(caps.clamp(settings) == settings)
    }

    @Test("codecChoices lists auto, supported codecs, then AV1 as inert when unsupported")
    func codecChoicesInertAV1() {
        let caps = StreamCapabilities.make(codecs: [.h264, .hevc], supportsTenBit: false,
                                           displaySize: nil, displayRefreshHz: nil)
        let choices = caps.codecChoices
        #expect(choices.map(\.codec) == [.auto, .h264, .hevc, .av1])
        #expect(choices.first { $0.codec == .av1 }?.enabled == false)
        #expect(choices.first { $0.codec == .h264 }?.enabled == true)
    }

    @Test("codecChoices enables AV1 and adds no duplicate when supported")
    func codecChoicesAV1Supported() {
        let choices = StreamCapabilities.unrestricted.codecChoices
        #expect(choices.filter { $0.codec == .av1 }.count == 1)
        #expect(choices.first { $0.codec == .av1 }?.enabled == true)
    }

    @Test("metalFXTarget returns the display when the stream is sub-native")
    func metalFXTargetSubNative() {
        let caps = StreamCapabilities.make(codecs: [.hevc], supportsTenBit: true,
                                           displaySize: PixelSize(width: 3840, height: 2160), displayRefreshHz: 60)
        #expect(caps.metalFXTarget(for: .hd1080) == PixelSize(width: 3840, height: 2160))
        #expect(caps.metalFXTarget(for: .qhd1440) == PixelSize(width: 3840, height: 2160))
    }

    @Test("metalFXTarget is nil at or above the display resolution")
    func metalFXTargetAtNative() {
        let caps = StreamCapabilities.make(codecs: [.hevc], supportsTenBit: true,
                                           displaySize: PixelSize(width: 3840, height: 2160), displayRefreshHz: 60)
        #expect(caps.metalFXTarget(for: .uhd4K) == nil)        // already native
        #expect(caps.metalFXTarget(for: .matchDisplay) == nil) // tracks the display, never beneficial
    }

    @Test("metalFXTarget is nil when the display resolution is unknown")
    func metalFXTargetUnknownDisplay() {
        let caps = StreamCapabilities.make(codecs: [.hevc], supportsTenBit: true,
                                           displaySize: nil, displayRefreshHz: nil)
        #expect(caps.metalFXTarget(for: .hd1080) == nil)
    }
}
