import Testing
import Foundation
import COpus
@testable import AudioEngine

@Suite("OpusAudioDecoder")
struct OpusAudioDecoderTests {
    /// Encode `frames` of a 440 Hz stereo sine into Opus packets with the vendored encoder.
    static func encodeStereoSine(frames: Int, frameSize: Int = 480, amplitude: Float = 0.5) -> [[UInt8]] {
        var err: Int32 = OPUS_OK
        let mapping: [UInt8] = [0, 1]
        let encoder = opus_multistream_encoder_create(48000, 2, 1, 1, mapping, OPUS_APPLICATION_AUDIO, &err)!
        defer { opus_multistream_encoder_destroy(encoder) }

        let step = 2.0 * Double.pi * 440.0 / 48000.0
        var phase = 0.0
        var packets: [[UInt8]] = []
        for _ in 0..<frames {
            var pcm = [Float](repeating: 0, count: frameSize * 2)
            for i in 0..<frameSize {
                let sample = Float(Double(amplitude) * sin(phase))
                phase += step
                pcm[2 * i] = sample
                pcm[2 * i + 1] = sample
            }
            var out = [UInt8](repeating: 0, count: 4000)
            let written = pcm.withUnsafeBufferPointer { input in
                out.withUnsafeMutableBufferPointer { output in
                    opus_multistream_encode_float(encoder, input.baseAddress!, Int32(frameSize),
                                                  output.baseAddress!, Int32(output.count))
                }
            }
            out.removeLast(out.count - max(0, Int(written)))
            packets.append(out)
        }
        return packets
    }

    static func makeStereoDecoder() throws -> OpusAudioDecoder {
        try OpusAudioDecoder(channelCount: 2, streams: 1, coupledStreams: 1, mapping: [0, 1], samplesPerFrame: 480)
    }

    @Test func decodesStereoFrameToInterleavedPCM() throws {
        let packets = Self.encodeStereoSine(frames: 1)
        let pcm = try Self.makeStereoDecoder().decode(packets[0])
        #expect(pcm.count == 480 * 2)
        #expect(pcm.allSatisfy { $0 >= -1.0 && $0 <= 1.0 })
    }

    @Test func decodedSignalCarriesEnergyAfterWarmup() throws {
        let packets = Self.encodeStereoSine(frames: 6)
        let decoder = try Self.makeStereoDecoder()
        var last: [Float] = []
        for packet in packets { last = try decoder.decode(packet) }
        let peak = last.map(abs).max() ?? 0
        #expect(peak > 0.05)
    }

    @Test func concealLossProducesOneFrame() throws {
        let pcm = try Self.makeStereoDecoder().concealLoss()
        #expect(pcm.count == 480 * 2)
        #expect(pcm.allSatisfy { $0.isFinite })
    }

    @Test func invalidConfigThrows() {
        #expect(throws: OpusAudioDecoder.Failure.self) {
            _ = try OpusAudioDecoder(channelCount: 2, streams: 0, coupledStreams: 0, mapping: [0, 1], samplesPerFrame: 480)
        }
    }
}
