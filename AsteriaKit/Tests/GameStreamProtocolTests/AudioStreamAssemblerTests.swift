import Testing
@testable import GameStreamProtocol

@Suite("Audio FEC reassembly (RS 4,2)")
struct AudioStreamAssemblerTests {
    let blockSize = 16

    private func rtpHeader(type: UInt8, seq: UInt16) -> [UInt8] {
        [0x80, type, UInt8(seq >> 8), UInt8(seq & 0xFF), 0, 0, 0, 0, 0, 0, 0, 0]
    }
    private func be16(_ v: UInt16) -> [UInt8] { [UInt8(v >> 8), UInt8(v & 0xFF)] }
    private func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }

    private func opus(_ i: Int) -> [UInt8] { (0..<blockSize).map { UInt8((i * 37 + $0 * 5 + 1) & 0xFF) } }

    private func buildBlock(baseSeq: UInt16) throws -> (data: [[UInt8]], parity: [[UInt8]]) {
        let payloads: [[UInt8]] = (0..<4).map { opus($0) }
        let parityPayloads = FECFixtureEncoder.parity(
            data: payloads,
            matrix: FECFixtureEncoder.audioMatrix
        )

        let data = (0..<4).map { rtpHeader(type: 97, seq: baseSeq &+ UInt16($0)) + opus($0) }
        let parity = (0..<2).map { p -> [UInt8] in
            let header = [UInt8(p), 97] + be16(baseSeq) + be32(0x2000) + be32(7)
            return rtpHeader(type: 127, seq: baseSeq &+ 100 &+ UInt16(p))
                + header + parityPayloads[p]
        }
        return (data, parity)
    }

    @Test func emitsEachDataPacketImmediatelyInSequence() async throws {
        let asm = try AudioStreamAssembler()
        let (data, _) = try buildBlock(baseSeq: 100)

        var emitted: [AudioOpusPacket] = []
        for (i, d) in data.enumerated() {
            let out = asm.ingest(d)
            #expect(out.map(\.sequenceNumber) == [100 &+ UInt16(i)])   // one packet per arrival, no block wait
            emitted += out
        }
        #expect(emitted.map(\.sequenceNumber) == [100, 101, 102, 103])
        #expect(emitted.allSatisfy { !$0.recovered })
        for i in 0..<4 { #expect(emitted[i].data == opus(i)) }
    }

    @Test func recoversDroppedDataShardFromParity() async throws {
        let asm = try AudioStreamAssembler()
        let (data, parity) = try buildBlock(baseSeq: 200)

        #expect(asm.ingest(data[0]).map(\.sequenceNumber) == [200])
        #expect(asm.ingest(data[1]).map(\.sequenceNumber) == [201])
        #expect(asm.ingest(data[3]).isEmpty)                 // 202 missing → 203 held behind the gap

        let out = asm.ingest(parity[0])                      // parity fills 202, unblocks 203
        #expect(out.map(\.sequenceNumber) == [202, 203])
        #expect(out[0].data == opus(2) && out[0].recovered)
        #expect(out[1].data == opus(3) && !out[1].recovered)
    }

    @Test func dropsLateShardsForEmittedBlock() async throws {
        let asm = try AudioStreamAssembler()
        let (data, parity) = try buildBlock(baseSeq: 300)
        for d in data { _ = asm.ingest(d) }
        #expect(asm.ingest(parity[0]).isEmpty)
    }

    @Test func reordersWithinBlockThenEmitsInOrder() async throws {
        let asm = try AudioStreamAssembler()
        let (data, _) = try buildBlock(baseSeq: 8)
        var emitted: [AudioOpusPacket] = []
        for i in [3, 0, 2, 1] { emitted += asm.ingest(data[i]) }
        #expect(emitted.map(\.sequenceNumber) == [8, 9, 10, 11])
    }

    @Test func skipsUnrecoverableGapOnceLeadIsReached() async throws {
        let asm = try AudioStreamAssembler()
        let (block, _) = try buildBlock(baseSeq: 400)
        let (next, _) = try buildBlock(baseSeq: 404)

        // 400 lost, no parity: 401/402/403 held while the gap can't be recovered.
        #expect(asm.ingest(block[1]).isEmpty)
        #expect(asm.ingest(block[2]).isEmpty)
        #expect(asm.ingest(block[3]).isEmpty)
        // Next block's first data puts us a full block ahead → skip the dead 400 and flush.
        let out = asm.ingest(next[0])
        #expect(out.map(\.sequenceNumber) == [401, 402, 403, 404])
    }
}
