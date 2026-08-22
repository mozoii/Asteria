import Testing
import CoreAudioTypes
@testable import AudioEngine

@Suite("ChannelRemap")
struct ChannelRemapTests {
    @Test func stereoIsIdentity() {
        let remap = ChannelRemap(channelCount: 2)
        #expect(remap?.sourceForDestination == [0, 1])
        #expect(remap?.layoutTag == kAudioChannelLayoutTag_Stereo)
        #expect(remap?.isIdentity == true)
        #expect(remap?.remap([1, 2, 3, 4]) == [1, 2, 3, 4])
    }

    @Test func surround51IsIdentity() {
        let remap = ChannelRemap(channelCount: 6)
        #expect(remap?.sourceForDestination == [0, 1, 2, 3, 4, 5])
        #expect(remap?.layoutTag == kAudioChannelLayoutTag_MPEG_5_1_A)
        #expect(remap?.isIdentity == true)
    }

    @Test func surround71SwapsSideAndRearPairs() {
        let remap = ChannelRemap(channelCount: 8)
        #expect(remap?.sourceForDestination == [0, 1, 2, 3, 6, 7, 4, 5])
        #expect(remap?.layoutTag == kAudioChannelLayoutTag_MPEG_7_1_C)
        #expect(remap?.isIdentity == false)
        // Two interleaved frames; sides (6,7) and rears (4,5) swap positions.
        let input: [Float] = [0, 1, 2, 3, 4, 5, 6, 7, 10, 11, 12, 13, 14, 15, 16, 17]
        let expected: [Float] = [0, 1, 2, 3, 6, 7, 4, 5, 10, 11, 12, 13, 16, 17, 14, 15]
        #expect(remap?.remap(input) == expected)
    }

    @Test func unsupportedChannelCountIsNil() {
        #expect(ChannelRemap(channelCount: 3) == nil)
        #expect(ChannelRemap(channelCount: 1) == nil)
    }
}
