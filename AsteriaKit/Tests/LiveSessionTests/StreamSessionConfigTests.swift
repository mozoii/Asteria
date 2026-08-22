import Testing
import GameStreamProtocol
@testable import LiveSession

@Suite("StreamSession.Configuration")
struct StreamSessionConfigTests {
    @Test("defaults assemble the live-validated 1080p60 stereo SDR wire config")
    func defaultsAssembleConfig() {
        let config = StreamSession.Configuration()
        let wire = config.streamConfiguration(
            videoFormat: .hevc, remoteInput: (key: [UInt8](repeating: 7, count: 16), keyId: 42))

        #expect(wire.width == 1920)
        #expect(wire.height == 1080)
        #expect(wire.fps == 60)
        #expect(wire.bitrateKbps == 20_000)
        #expect(wire.packetSize == 1392)
        #expect(wire.videoFormat == .hevc)
        #expect(!wire.hdr)
        #expect(wire.remoteInputAesKeyId == 42)
        #expect(wire.remoteInputAesKey.count == 16)
        #expect(wire.modeString == "1920x1080x60")
    }

    @Test("a custom appId and codec flow through to the wire config")
    func customValues() {
        let config = StreamSession.Configuration(appId: "12345", bitrateKbps: 30_000)
        #expect(config.appId == "12345")
        let wire = config.streamConfiguration(videoFormat: .h264, remoteInput: (key: [], keyId: 1))
        #expect(wire.videoFormat == .h264)
        #expect(wire.bitrateKbps == 30_000)
    }
}
