import Testing
import COpus

/// Proves the vendored libopus links and decodes by running one concealment (NULL-packet) frame.
@Suite("COpus vendored libopus")
struct COpusSmokeTests {
    @Test func createsDecodesAndDestroysStereoDecoder() {
        var err: Int32 = -1
        let mapping: [UInt8] = [0, 1]
        let decoder = opus_multistream_decoder_create(48000, 2, 1, 1, mapping, &err)
        #expect(err == OPUS_OK)
        #expect(decoder != nil)
        guard let decoder else { return }
        defer { opus_multistream_decoder_destroy(decoder) }

        let frameSize: Int32 = 480
        var pcm = [Float](repeating: .nan, count: Int(frameSize) * 2)
        let decoded = opus_multistream_decode_float(decoder, nil, 0, &pcm, frameSize, 0)
        #expect(decoded == frameSize)
    }
}
