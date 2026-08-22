import Testing
@testable import VideoEngine

@Suite("Annex B → AVCC length-prefixing")
struct AVCCTests {
    @Test("prefixes each NAL with its 4-byte big-endian length")
    func lengthPrefixes() {
        let nals: [ArraySlice<UInt8>] = [
            [0x65, 0x01, 0x02][...],   // 3 bytes
            [0x41, 0x09][...],         // 2 bytes
        ]
        let avcc = AVCC.encode(nals)
        #expect(avcc == [
            0x00, 0x00, 0x00, 0x03, 0x65, 0x01, 0x02,
            0x00, 0x00, 0x00, 0x02, 0x41, 0x09,
        ])
    }

    @Test("skips empty NALs and handles the empty input")
    func skipsEmpty() {
        #expect(AVCC.encode([]) == [])
        #expect(AVCC.encode([[][...], [0xAB][...]]) == [0x00, 0x00, 0x00, 0x01, 0xAB])
    }

    @Test("round-trips back through the Annex B scanner when start-code-delimited")
    func roundTripWithScanner() {
        let annexB: [UInt8] = [0, 0, 0, 1, 0x67, 0xAA, 0, 0, 1, 0x68, 0xCC, 0xDD]
        let nals = AnnexB.nalUnits(in: annexB)
        let avcc = AVCC.encode(nals)
        #expect(avcc == [
            0x00, 0x00, 0x00, 0x02, 0x67, 0xAA,
            0x00, 0x00, 0x00, 0x03, 0x68, 0xCC, 0xDD,
        ])
    }
}
