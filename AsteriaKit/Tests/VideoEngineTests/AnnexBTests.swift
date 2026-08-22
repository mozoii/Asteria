import Testing
@testable import VideoEngine

@Suite("Annex B NAL scanning")
struct AnnexBTests {
    @Test("splits a mix of 3- and 4-byte start codes into NAL units")
    func splitsMixedStartCodes() {
        let stream: [UInt8] = [
            0, 0, 0, 1, 0x67, 0xAA, 0xBB,          // 4-byte start code → NAL "67 AA BB"
            0, 0, 1, 0x68, 0xCC,                    // 3-byte start code → NAL "68 CC"
            0, 0, 0, 1, 0x65, 0x01, 0x02, 0x03,     // 4-byte start code → NAL "65 01 02 03"
        ]
        let nals = AnnexB.nalUnits(in: stream)
        #expect(nals.count == 3)
        #expect(Array(nals[0]) == [0x67, 0xAA, 0xBB])
        #expect(Array(nals[1]) == [0x68, 0xCC])
        #expect(Array(nals[2]) == [0x65, 0x01, 0x02, 0x03])
    }

    @Test("ignores bytes before the first start code")
    func ignoresLeadingGarbage() {
        let stream: [UInt8] = [0xDE, 0xAD, 0, 0, 0, 1, 0x67, 0x11]
        let nals = AnnexB.nalUnits(in: stream)
        #expect(nals.count == 1)
        #expect(Array(nals[0]) == [0x67, 0x11])
    }

    @Test("skips empty NALs from consecutive start codes")
    func skipsEmptyNALs() {
        let stream: [UInt8] = [
            0, 0, 0, 1,                 // start code with no payload before the next one
            0, 0, 1, 0x41, 0x09,        // real NAL "41 09"
        ]
        let nals = AnnexB.nalUnits(in: stream)
        #expect(nals.count == 1)
        #expect(Array(nals[0]) == [0x41, 0x09])
    }

    @Test("returns nothing for a stream with no start code")
    func noStartCode() {
        #expect(AnnexB.nalUnits(in: [0x01, 0x02, 0x03]).isEmpty)
    }
}
