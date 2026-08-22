import Testing
import GameStreamProtocol
@testable import VideoEngine

@Suite("Decoder capabilities → format policy")
struct DecoderCapabilitiesTests {
    @Test("M1/M2-class (no AV1) with HDR: prefers HEVC Main10, excludes AV1")
    func hevcNoAV1() {
        let caps = DecoderCapabilities(h264: true, hevc: true, hevcMain10: true, hdrDisplay: true)
        #expect(caps.preferredFormat() == .hevcMain10)
        let formats = caps.supportedFormats()
        #expect(formats.contains(.h264))
        #expect(formats.contains(.hevc))
        #expect(formats.contains(.hevcMain10))
        #expect(!formats.contains(.av1Main8))
    }

    @Test("supportsHDR requires an EDR display and HEVC Main10; AV1 alone can't carry HDR")
    func supportsHDRGate() {
        #expect(DecoderCapabilities(hevc: true, hevcMain10: true, hdrDisplay: true).supportsHDR)
        #expect(!DecoderCapabilities(av1: true, av1Main10: true, hdrDisplay: true).supportsHDR)   // no AV1 decode path
        #expect(!DecoderCapabilities(hevc: true, hevcMain10: true, hdrDisplay: false).supportsHDR)
        #expect(!DecoderCapabilities(hevc: true, hevcMain10: false, hdrDisplay: true).supportsHDR)
    }

    @Test("M3+-class with HDR: prefers AV1 Main10")
    func av1HDR() {
        let caps = DecoderCapabilities(h264: true, hevc: true, hevcMain10: true,
                                       av1: true, av1Main10: true, hdrDisplay: true)
        #expect(caps.preferredFormat() == .av1Main10)
        #expect(caps.supportedFormats().contains(.av1Main10))
    }

    @Test("SDR display: prefers 8-bit even when 10-bit is decodable")
    func sdrPrefers8Bit() {
        let caps = DecoderCapabilities(hevc: true, hevcMain10: true, hdrDisplay: false)
        #expect(caps.preferredFormat() == .hevc)
    }

    @Test("H.264 only")
    func h264Only() {
        let caps = DecoderCapabilities(h264: true)
        #expect(caps.preferredFormat() == .h264)
        #expect(caps.supportedFormats() == .h264)
    }

    @Test("no decoders: no preferred format")
    func noDecoders() {
        #expect(DecoderCapabilities().preferredFormat() == nil)
        #expect(DecoderCapabilities().supportedFormats().isEmpty)
    }

    @Test("probe reports at least one HW codec on Apple Silicon")
    func probeSmoke() {
        let caps = DecoderCapabilities.probe(hdrDisplay: false)
        #expect(caps.h264 || caps.hevc)
    }

    /// Full Sunshine offer: H.264 + HEVC + HEVC10 + AV1 + AV1-10.
    private static let sunshineOffer: VideoFormat =
        [.h264, .hevc, .hevcMain10, .av1Main8, .av1Main10]

    @Test("M3+ SDR: negotiates AV1 8-bit (AV1 over HEVC; 8-bit for SDR)")
    func negotiatesAV1ForM3SDR() {
        let caps = DecoderCapabilities(h264: true, hevc: true, hevcMain10: true,
                                       av1: true, av1Main10: true, hdrDisplay: false)
        #expect(caps.negotiatedFormat(hostFormats: Self.sunshineOffer) == .av1Main8)
    }

    @Test("M1/M2 SDR: negotiates HEVC 8-bit (no AV1 decoder)")
    func negotiatesHEVCForM1SDR() {
        let caps = DecoderCapabilities(h264: true, hevc: true, hevcMain10: true, hdrDisplay: false)
        #expect(caps.negotiatedFormat(hostFormats: Self.sunshineOffer) == .hevc)
    }

    @Test("HDR display + M3: negotiates AV1 Main10")
    func negotiatesAV1Main10ForHDR() {
        let caps = DecoderCapabilities(h264: true, hevc: true, hevcMain10: true,
                                       av1: true, av1Main10: true, hdrDisplay: true)
        #expect(caps.negotiatedFormat(hostFormats: Self.sunshineOffer) == .av1Main10)
    }

    @Test("host offers only H.264: HEVC-capable Mac falls back to H.264")
    func fallsBackToH264WhenHostHasNoHEVC() {
        let caps = DecoderCapabilities(h264: true, hevc: true, hevcMain10: true, av1: true, av1Main10: true)
        #expect(caps.negotiatedFormat(hostFormats: .h264) == .h264)
    }

    @Test("SDR + preferTenBit: negotiates HEVC Main10 without an HDR display")
    func sdrPrefersTenBitWhenRequested() {
        let caps = DecoderCapabilities(h264: true, hevc: true, hevcMain10: true, hdrDisplay: false)
        #expect(caps.negotiatedFormat(hostFormats: Self.sunshineOffer, preferTenBit: true) == .hevcMain10)
        #expect(caps.preferredFormat(preferTenBit: true) == .hevcMain10)
    }

    @Test("preferTenBit is moot when the decoder lacks 10-bit")
    func preferTenBitWithoutDecoder() {
        let caps = DecoderCapabilities(h264: true, hevc: true, hevcMain10: false, hdrDisplay: false)
        #expect(caps.negotiatedFormat(hostFormats: Self.sunshineOffer, preferTenBit: true) == .hevc)
    }

    @Test("no common format: negotiation yields nil")
    func noOverlapYieldsNil() {
        // M1 (no AV1) against an AV1-only host.
        let caps = DecoderCapabilities(h264: false, hevc: false)
        #expect(caps.negotiatedFormat(hostFormats: [.av1Main8, .av1Main10]) == nil)
    }

    @Test("a codec pin selects that codec when host + Mac support it")
    func codecPinHonored() {
        let caps = DecoderCapabilities(h264: true, hevc: true, hevcMain10: true,
                                       av1: true, av1Main10: true, hdrDisplay: false)
        // Unrestricted would pick AV1; pinning HEVC selects HEVC, pinning H.264 wins over newer codecs.
        #expect(caps.negotiatedFormat(hostFormats: Self.sunshineOffer, restrictedTo: .maskHevc) == .hevc)
        #expect(caps.negotiatedFormat(hostFormats: Self.sunshineOffer, restrictedTo: .maskH264) == .h264)
    }

    @Test("a codec pin the host can't satisfy falls back to the best available")
    func codecPinFallsBack() {
        let caps = DecoderCapabilities(h264: true, hevc: true, hevcMain10: true, hdrDisplay: false)
        #expect(caps.negotiatedFormat(hostFormats: .h264, restrictedTo: .maskHevc) == .h264)
    }

    @Test("a nil codec restriction matches the unrestricted negotiation")
    func nilRestrictionIsUnrestricted() {
        let caps = DecoderCapabilities(h264: true, hevc: true, hevcMain10: true,
                                       av1: true, av1Main10: true, hdrDisplay: false)
        #expect(caps.negotiatedFormat(hostFormats: Self.sunshineOffer, restrictedTo: nil)
                == caps.negotiatedFormat(hostFormats: Self.sunshineOffer))
    }

    @Test("a codec pin still honors 10-bit preference within the codec")
    func codecPinWithTenBit() {
        let caps = DecoderCapabilities(h264: true, hevc: true, hevcMain10: true, hdrDisplay: false)
        #expect(caps.negotiatedFormat(hostFormats: Self.sunshineOffer, restrictedTo: .maskHevc,
                                      preferTenBit: true) == .hevcMain10)
    }

    @Test("RFI is supported for HEVC and AV1, not H.264")
    func rfiCodecSupport() {
        #expect(DecoderCapabilities.supportsReferenceFrameInvalidation(for: .hevc))
        #expect(DecoderCapabilities.supportsReferenceFrameInvalidation(for: .hevcMain10))
        #expect(DecoderCapabilities.supportsReferenceFrameInvalidation(for: .av1Main8))
        #expect(!DecoderCapabilities.supportsReferenceFrameInvalidation(for: .h264))
        #expect(!DecoderCapabilities.supportsReferenceFrameInvalidation(for: .h264High8_444))
    }
}
