import Testing
@testable import GameStreamProtocol

@Suite("StreamConfiguration (launch facts)")
struct StreamConfigurationTests {

    private func config() -> StreamConfiguration {
        StreamConfiguration(
            width: 1920, height: 1080, fps: 60,
            bitrateKbps: 20_000, packetSize: 1392,
            videoFormat: .h264, audio: .stereo, hdr: false,
            remoteInputAesKey: Array(0..<16), remoteInputAesKeyId: 0x01020304
        )
    }

    @Test func modeStringIsWidthHeightFps() {
        #expect(config().modeString == "1920x1080x60")
    }

    @Test func rikeyHexIsLowercaseHexOfKey() {
        #expect(config().rikeyHex == "000102030405060708090a0b0c0d0e0f")
    }

    @Test func surroundAudioInfoPacksMaskAndCount() {
        #expect(config().surroundAudioInfo == (0x3 << 16) | 2)
        let s51 = StreamConfiguration(
            width: 1, height: 1, fps: 1, bitrateKbps: 1, packetSize: 1,
            videoFormat: .hevc, audio: .surround51, hdr: false,
            remoteInputAesKey: Array(repeating: 0, count: 16), remoteInputAesKeyId: 0
        )
        #expect(s51.surroundAudioInfo == (0x3F << 16) | 6)
    }

    @Test func randomRemoteInputKeyIs16Bytes() {
        let (key, _) = StreamConfiguration.randomRemoteInput()
        #expect(key.count == 16)

        let (key2, _) = StreamConfiguration.randomRemoteInput()
        #expect(key != key2)   // fresh randomness per call
    }
}
