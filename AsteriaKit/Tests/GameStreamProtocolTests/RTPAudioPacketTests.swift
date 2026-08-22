import Testing
@testable import GameStreamProtocol

@Suite("RTP audio packet parse")
struct RTPAudioPacketTests {
    private func rtpHeader(type: UInt8, seq: UInt16, ts: UInt32, ssrc: UInt32) -> [UInt8] {
        [0x80, type,
         UInt8(seq >> 8), UInt8(seq & 0xFF),
         UInt8(ts >> 24), UInt8((ts >> 16) & 0xFF), UInt8((ts >> 8) & 0xFF), UInt8(ts & 0xFF),
         UInt8(ssrc >> 24), UInt8((ssrc >> 16) & 0xFF), UInt8((ssrc >> 8) & 0xFF), UInt8(ssrc & 0xFF)]
    }

    @Test func parsesDataPacketOpusPayload() throws {
        let opus: [UInt8] = [0xDE, 0xAD, 0xBE, 0xEF, 0x01]
        let datagram = rtpHeader(type: 97, seq: 0x1234, ts: 0x0000_2000, ssrc: 0x0000_0007) + opus
        let p = try #require(RTPAudioPacket(parsing: datagram))
        #expect(p.isData)
        #expect(!p.isFec)
        #expect(p.sequenceNumber == 0x1234)
        #expect(p.timestamp == 0x0000_2000)
        #expect(p.ssrc == 7)
        #expect(p.payload == opus)
        #expect(p.fecHeader == nil)
    }

    @Test func parsesFecPacketHeaderAndParity() throws {
        let parity: [UInt8] = [0x11, 0x22, 0x33, 0x44]
        let fecHeader: [UInt8] = [0x01, 97,
                                  0x12, 0x30,                 // baseSeq 0x1230 BE
                                  0x00, 0x00, 0x20, 0x00,     // baseTs 0x2000 BE
                                  0x00, 0x00, 0x00, 0x07]     // ssrc 7 BE
        let datagram = rtpHeader(type: 127, seq: 0x1240, ts: 0, ssrc: 7) + fecHeader + parity
        let p = try #require(RTPAudioPacket(parsing: datagram))
        #expect(p.isFec)
        let h = try #require(p.fecHeader)
        #expect(h.fecShardIndex == 1)
        #expect(h.payloadType == 97)
        #expect(h.baseSequenceNumber == 0x1230)
        #expect(h.baseTimestamp == 0x2000)
        #expect(h.ssrc == 7)
        #expect(p.parity == parity)
    }

    @Test func rejectsTooShort() {
        #expect(RTPAudioPacket(parsing: [0x80, 97, 0x00]) == nil)
    }

    @Test func fecHeaderNilWhenPayloadTooShort() throws {
        let datagram = rtpHeader(type: 127, seq: 1, ts: 0, ssrc: 0) + [0x01, 0x02, 0x03]
        let p = try #require(RTPAudioPacket(parsing: datagram))
        #expect(p.isFec)
        #expect(p.fecHeader == nil)
        #expect(p.parity == nil)
    }
}
