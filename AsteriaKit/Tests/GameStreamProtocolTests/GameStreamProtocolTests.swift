import Testing
@testable import GameStreamProtocol

@Suite("GameStream wire constants (facts)")
struct GameStreamProtocolTests {

    @Test func videoFormatBitfield() {
        #expect(VideoFormat.h264.rawValue == 0x0001)
        #expect(VideoFormat.hevc.rawValue == 0x0100)
        #expect(VideoFormat.hevcMain10.rawValue == 0x0200)
        #expect(VideoFormat.av1Main8.rawValue == 0x1000)
        #expect(VideoFormat.av1Main10.rawValue == 0x2000)
    }

    @Test func videoFormatMasks() {
        #expect(VideoFormat.mask10Bit.contains(.hevcMain10))
        #expect(VideoFormat.mask10Bit.contains(.av1Main10))
        #expect(!VideoFormat.mask10Bit.contains(.h264))
        #expect(VideoFormat.mask444.contains(.av1High10_444))
        #expect(VideoFormat.maskHevc.contains(.hevc))
    }

    @Test func audioConfigurations() {
        #expect(AudioConfiguration.stereo.channelCount == 2)
        #expect(AudioConfiguration.stereo.channelMask == 0x3)
        #expect(AudioConfiguration.surround51.channelCount == 6)
        #expect(AudioConfiguration.surround51.channelMask == 0x3F)
        #expect(AudioConfiguration.surround71.channelCount == 8)
        #expect(AudioConfiguration.surround71.channelMask == 0x63F)
    }

}
