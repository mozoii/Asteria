import COpus

/// Wraps a libopus multistream decoder: Opus packets → interleaved Float32 PCM, with concealment for loss.
public final class OpusAudioDecoder {
    public enum Failure: Error, Equatable {
        case decoderCreateFailed(Int32)
        case decodeFailed(Int32)
    }

    /// 120 ms at 48 kHz — the largest possible Opus frame, so one decode call always has output room.
    private static let maxSamplesPerChannel = 5760

    private let decoder: OpaquePointer
    public let channelCount: Int
    public let sampleRate: Int32
    /// Frame length concealed for a lost packet (host AudioPacketDuration × 48 samples/ms).
    public let samplesPerFrame: Int

    public init(sampleRate: Int32 = 48000, channelCount: Int, streams: Int,
                coupledStreams: Int, mapping: [UInt8], samplesPerFrame: Int) throws {
        var err: Int32 = OPUS_OK
        guard let decoder = opus_multistream_decoder_create(
            sampleRate, Int32(channelCount), Int32(streams), Int32(coupledStreams), mapping, &err),
            err == OPUS_OK else {
            throw Failure.decoderCreateFailed(err)
        }
        self.decoder = decoder
        self.channelCount = channelCount
        self.sampleRate = sampleRate
        self.samplesPerFrame = samplesPerFrame
    }

    deinit { opus_multistream_decoder_destroy(decoder) }

    /// Decode one Opus packet; result count == decoded-samples-per-channel × channelCount.
    public func decode(_ packet: [UInt8]) throws -> [Float] {
        try render(packet: packet, frameSize: Int32(Self.maxSamplesPerChannel))
    }

    /// Conceal one lost packet (decode with no data): produces `samplesPerFrame` frames of PLC audio.
    public func concealLoss() throws -> [Float] {
        try render(packet: nil, frameSize: Int32(samplesPerFrame))
    }

    private func render(packet: [UInt8]?, frameSize: Int32) throws -> [Float] {
        var pcm = [Float](repeating: 0, count: Self.maxSamplesPerChannel * channelCount)
        let decoded = pcm.withUnsafeMutableBufferPointer { out -> Int32 in
            if let packet {
                return packet.withUnsafeBufferPointer { input in
                    opus_multistream_decode_float(decoder, input.baseAddress, Int32(input.count),
                                                  out.baseAddress!, frameSize, 0)
                }
            }
            return opus_multistream_decode_float(decoder, nil, 0, out.baseAddress!, frameSize, 0)
        }
        guard decoded >= 0 else { throw Failure.decodeFailed(decoded) }
        pcm.removeLast(pcm.count - Int(decoded) * channelCount)
        return pcm
    }
}
