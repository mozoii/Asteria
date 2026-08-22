import Foundation

/// Opus multistream layout for the decoder, derived from the negotiated audio config + server SDP.
public struct OpusMultistreamConfig: Sendable, Equatable {
    public let sampleRate: Int32
    public let channelCount: Int
    public let streams: Int
    public let coupledStreams: Int
    public let samplesPerFrame: Int
    public let mapping: [UInt8]

    public init(sampleRate: Int32, channelCount: Int, streams: Int,
                coupledStreams: Int, samplesPerFrame: Int, mapping: [UInt8]) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.streams = streams
        self.coupledStreams = coupledStreams
        self.samplesPerFrame = samplesPerFrame
        self.mapping = mapping
    }

    public static func derive(audio: AudioConfiguration, serverSDP: String,
                              packetDurationMs: Int = 5) -> OpusMultistreamConfig? {
        let samplesPerFrame = 48 * packetDurationMs
        switch audio.channelCount {
        case 2:
            return OpusMultistreamConfig(sampleRate: 48000, channelCount: 2, streams: 1,
                                         coupledStreams: 1, samplesPerFrame: samplesPerFrame, mapping: [0, 1])
        case 6, 8:
            if let params = surroundParams(in: serverSDP).first, params.channelCount == audio.channelCount {
                return OpusMultistreamConfig(
                    sampleRate: 48000, channelCount: params.channelCount, streams: params.streams,
                    coupledStreams: params.coupledStreams, samplesPerFrame: samplesPerFrame,
                    mapping: gfeToClientMapping(params.mapping))
            }
            if audio.channelCount == 6 {
                return OpusMultistreamConfig(sampleRate: 48000, channelCount: 6, streams: 4,
                                             coupledStreams: 2, samplesPerFrame: samplesPerFrame,
                                             mapping: [0, 4, 1, 5, 2, 3])
            }
            return nil
        default:
            return nil
        }
    }

    struct SurroundParams: Equatable {
        let channelCount: Int
        let streams: Int
        let coupledStreams: Int
        let mapping: [UInt8]
    }

    static func surroundParams(in sdp: String) -> [SurroundParams] {
        var results: [SurroundParams] = []
        let marker = "surround-params="
        var search = sdp.startIndex
        while let range = sdp.range(of: marker, range: search..<sdp.endIndex) {
            search = range.upperBound
            let digits = sdp[range.upperBound...].prefix { $0.isASCII && $0.isNumber }
                .compactMap { $0.wholeNumberValue }
            guard digits.count >= 3 else { continue }
            let channelCount = digits[0]
            guard digits.count >= 3 + channelCount, channelCount > 0 else { continue }
            results.append(SurroundParams(
                channelCount: channelCount, streams: digits[1], coupledStreams: digits[2],
                mapping: digits[3..<(3 + channelCount)].map { UInt8($0) }))
        }
        return results
    }

    static func gfeToClientMapping(_ gfe: [UInt8]) -> [UInt8] {
        let channels = gfe.count
        guard channels >= 4 else { return gfe }
        var client = gfe
        client[3] = gfe[channels - 1]
        for i in 0..<(channels - 4) { client[4 + i] = gfe[3 + i] }
        return client
    }
}
