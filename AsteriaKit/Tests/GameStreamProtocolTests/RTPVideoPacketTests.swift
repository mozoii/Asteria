import Testing
import Foundation
@testable import GameStreamProtocol

@Suite("RTP video packet parse (NV video header)")
struct RTPVideoPacketTests {
    private func buildPacket(extension hasExt: Bool, seq: UInt16, frame: UInt32, spi: UInt32,
                             flags: UInt8, fecInfo: UInt32, multiFecBlocks: UInt8,
                             payload: [UInt8]) -> [UInt8] {
        var b: [UInt8] = []
        b.append(hasExt ? 0x90 : 0x80)
        b.append(0x00)
        b.append(contentsOf: [UInt8(seq >> 8), UInt8(seq & 0xFF)])
        b.append(contentsOf: [0xDE, 0xAD, 0xBE, 0xEF])
        b.append(contentsOf: [0x12, 0x34, 0x56, 0x78])
        if hasExt { b.append(contentsOf: [0, 0, 0, 0]) }
        b.append(contentsOf: le32(spi))
        b.append(contentsOf: le32(frame))
        b.append(flags)
        b.append(0x00)
        b.append(0x10)
        b.append(multiFecBlocks)
        b.append(contentsOf: le32(fecInfo))
        b.append(contentsOf: payload)
        return b
    }
    private func le32(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
    }

    @Test func parsesHeadersAndDerivedFecFields() throws {
        let fecInfo: UInt32 = (10 << 22) | (3 << 12) | (20 << 4)
        let multiFecBlocks: UInt8 = (1 << 4) | (2 << 6)
        let payload: [UInt8] = [0xAA, 0xBB, 0xCC, 0xDD]
        let bytes = buildPacket(extension: false, seq: 0x0102, frame: 7, spi: 42,
                                flags: 0x05, fecInfo: fecInfo, multiFecBlocks: multiFecBlocks, payload: payload)

        let p = try #require(RTPVideoPacket(parsing: bytes))
        #expect(p.sequenceNumber == 0x0102)
        #expect(p.timestamp == 0xDEADBEEF)
        #expect(p.ssrc == 0x12345678)
        #expect(p.frameIndex == 7)
        #expect(p.streamPacketIndex == 42)
        #expect(p.flags == 0x05)

        #expect(p.fecIndex == 3)
        #expect(p.dataShards == 10)
        #expect(p.fecPercentage == 20)
        #expect(p.parityShards == 2)
        #expect(p.currentFecBlock == 1)
        #expect(p.lastFecBlock == 2)

        #expect(p.isFrameStart)
        #expect(p.containsPicData)
        #expect(!p.isFrameEnd)
        #expect(!p.isParity)
    }

    @Test func honorsRtpExtensionOffset() throws {
        let fecInfo: UInt32 = (4 << 22) | (0 << 12) | (50 << 4)
        let bytes = buildPacket(extension: true, seq: 9, frame: 1, spi: 1,
                                flags: 0x02, fecInfo: fecInfo, multiFecBlocks: 0, payload: [0x01, 0x02])
        let p = try #require(RTPVideoPacket(parsing: bytes))
        #expect(p.hasExtension)
        #expect(p.frameIndex == 1)
        #expect(p.dataShards == 4)
        #expect(p.parityShards == 2)
        #expect(p.isFrameEnd)
    }

    @Test func parityShardDetected() throws {
        let fecInfo: UInt32 = (4 << 22) | (5 << 12) | (50 << 4)
        let bytes = buildPacket(extension: false, seq: 5, frame: 2, spi: 2,
                                flags: 0x01, fecInfo: fecInfo, multiFecBlocks: 0, payload: [0xFF])
        let p = try #require(RTPVideoPacket(parsing: bytes))
        #expect(p.fecIndex == 5)
        #expect(p.dataShards == 4)
        #expect(p.isParity)
    }

    @Test func rejectsTruncatedPacket() {
        #expect(RTPVideoPacket(parsing: [UInt8](repeating: 0, count: 10)) == nil)
        #expect(RTPVideoPacket(parsing: [UInt8](repeating: 0, count: 20)) == nil)
    }
}
