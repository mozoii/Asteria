import Testing
@testable import GameStreamProtocol

@Suite("OpusMultistreamConfig.derive")
struct OpusMultistreamConfigTests {
    @Test func stereoIsFixedAndIgnoresSDP() {
        let config = OpusMultistreamConfig.derive(audio: .stereo, serverSDP: "v=0\r\n")
        #expect(config == OpusMultistreamConfig(sampleRate: 48000, channelCount: 2, streams: 1,
                                                coupledStreams: 1, samplesPerFrame: 240, mapping: [0, 1]))
    }

    @Test func packetDurationDrivesSamplesPerFrame() {
        let config = OpusMultistreamConfig.derive(audio: .stereo, serverSDP: "", packetDurationMs: 10)
        #expect(config?.samplesPerFrame == 480)
    }

    @Test func surround51FallsBackWhenNoParams() {
        let config = OpusMultistreamConfig.derive(audio: .surround51, serverSDP: "v=0\r\nno params here\r\n")
        #expect(config == OpusMultistreamConfig(sampleRate: 48000, channelCount: 6, streams: 4,
                                                coupledStreams: 2, samplesPerFrame: 240, mapping: [0, 4, 1, 5, 2, 3]))
    }

    @Test func surround71FailsWithoutParams() {
        #expect(OpusMultistreamConfig.derive(audio: .surround71, serverSDP: "v=0\r\n") == nil)
    }

    @Test func surround51ParsesAndReordersSDPMapping() {
        let sdp = "v=0\r\na=fmtp:97 surround-params=642012345\r\nt=0 0\r\n"
        let config = OpusMultistreamConfig.derive(audio: .surround51, serverSDP: sdp)
        // GFE mapping [0,1,2,3,4,5] -> client [0,1,2,5,3,4] (LFE to slot 3, surrounds shift up).
        #expect(config == OpusMultistreamConfig(sampleRate: 48000, channelCount: 6, streams: 4,
                                                coupledStreams: 2, samplesPerFrame: 240, mapping: [0, 1, 2, 5, 3, 4]))
    }

    @Test func surround71ParsesAndReordersSDPMapping() {
        let sdp = "a=fmtp:97 surround-params=85301234567\r\n"
        let config = OpusMultistreamConfig.derive(audio: .surround71, serverSDP: sdp)
        #expect(config == OpusMultistreamConfig(sampleRate: 48000, channelCount: 8, streams: 5,
                                                coupledStreams: 3, samplesPerFrame: 240,
                                                mapping: [0, 1, 2, 7, 3, 4, 5, 6]))
    }

    @Test func firstSurroundParamsWins() {
        // Normal-quality occurrence first, high-quality second; derive must use the first.
        let sdp = "a=fmtp:97 surround-params=642012345\r\na=fmtp:97 surround-params=642543210\r\n"
        #expect(OpusMultistreamConfig.derive(audio: .surround51, serverSDP: sdp)?.mapping == [0, 1, 2, 5, 3, 4])
    }

    @Test func parserReturnsAllOccurrencesInOrder() {
        let sdp = "surround-params=642012345 surround-params=853076543210"
        let parsed = OpusMultistreamConfig.surroundParams(in: sdp)
        #expect(parsed.count == 2)
        #expect(parsed[0] == .init(channelCount: 6, streams: 4, coupledStreams: 2, mapping: [0, 1, 2, 3, 4, 5]))
        #expect(parsed[1] == .init(channelCount: 8, streams: 5, coupledStreams: 3, mapping: [0, 7, 6, 5, 4, 3, 2, 1]))
    }

    @Test func gfeToClientMappingReorders() {
        #expect(OpusMultistreamConfig.gfeToClientMapping([0, 1, 2, 3, 4, 5]) == [0, 1, 2, 5, 3, 4])
        #expect(OpusMultistreamConfig.gfeToClientMapping([0, 1, 2, 3, 4, 5, 6, 7]) == [0, 1, 2, 7, 3, 4, 5, 6])
    }
}
