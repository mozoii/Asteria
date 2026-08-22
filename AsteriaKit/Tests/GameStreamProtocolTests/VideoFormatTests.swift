import Testing
@testable import GameStreamProtocol

/// Map VideoFormat from serverCodecModeSupport bitfield (base + Sunshine extension bits).
@Suite("VideoFormat ← serverCodecModeSupport")
struct VideoFormatTests {
    @Test("base H.264/HEVC bits map straight through")
    func baseBits() {
        let f = VideoFormat.fromServerCodecModeSupport(0x0001 | 0x0100 | 0x0200)
        #expect(f == [.h264, .hevc, .hevcMain10])
    }

    @Test("Sunshine AV1 extension bits remap to the VideoFormat positions")
    func av1ExtensionBits() {
        let f = VideoFormat.fromServerCodecModeSupport(0x00010000 | 0x00020000)
        #expect(f == [.av1Main8, .av1Main10])
        #expect(!f.contains(.h264High8_444))
    }

    @Test("Sunshine 4:4:4 extension bits remap correctly")
    func yuv444ExtensionBits() {
        let f = VideoFormat.fromServerCodecModeSupport(
            0x00040000 | 0x00080000 | 0x00100000 | 0x00200000 | 0x00400000)
        #expect(f == [.h264High8_444, .hevcRext8_444, .hevcRext10_444, .av1High8_444, .av1High10_444])
    }

    @Test("a full Sunshine offer maps to every advertised format")
    func fullOffer() {
        let scm = 0x0001 | 0x0100 | 0x0200 | 0x00010000 | 0x00020000
        let f = VideoFormat.fromServerCodecModeSupport(scm)
        #expect(f.contains(.h264) && f.contains(.hevc) && f.contains(.hevcMain10))
        #expect(f.contains(.av1Main8) && f.contains(.av1Main10))
    }

    @Test("zero offer is empty (host that didn't set the field)")
    func emptyOffer() {
        #expect(VideoFormat.fromServerCodecModeSupport(0).isEmpty)
    }

    @Test("isTenBit is true only for 10-bit formats")
    func tenBitClassification() {
        #expect(VideoFormat.hevcMain10.isTenBit)
        #expect(VideoFormat.hevcRext10_444.isTenBit)
        #expect(VideoFormat.av1Main10.isTenBit)
        #expect(VideoFormat.av1High10_444.isTenBit)

        #expect(!VideoFormat.h264.isTenBit)
        #expect(!VideoFormat.hevc.isTenBit)
        #expect(!VideoFormat.hevcRext8_444.isTenBit)
        #expect(!VideoFormat.av1Main8.isTenBit)
        #expect(!VideoFormat().isTenBit)
    }
}
