import Testing
import Foundation
@testable import GameStreamProtocol

@Suite("Video frame assembler (RTP + FEC)")
struct VideoFrameAssemblerTests {
    let packetSize = 48
    let videoLen = 32
    let dataOffset = 12

    private func datagram(seq: UInt16, frame: UInt32, fecIndex: Int, dataShards: Int,
                          fecPercentage: Int, flags: UInt8, multiFecBlocks: UInt8, video: [UInt8]) -> [UInt8] {
        var b: [UInt8] = [0x80, 0x00]
        b.append(contentsOf: [UInt8(seq >> 8), UInt8(seq & 0xFF)])
        b.append(contentsOf: [0, 0, 0, 1])
        b.append(contentsOf: [0, 0, 0, 2])
        b.append(contentsOf: le32(0))
        b.append(contentsOf: le32(frame))
        b.append(flags); b.append(0x00); b.append(0x10); b.append(multiFecBlocks)
        let fecInfo = UInt32((dataShards << 22) | (fecIndex << 12) | (fecPercentage << 4))
        b.append(contentsOf: le32(fecInfo))
        b.append(contentsOf: video)
        return b
    }
    private func le32(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
    }
    private func video(_ shard: Int) -> [UInt8] { (0..<videoLen).map { UInt8((shard * 17 + $0) & 0xFF) } }

    private func buildFrame(frame: UInt32, dataShards D: Int, fecPercentage pct: Int, baseSeq: UInt16)
        throws -> (data: [[UInt8]], parity: [[UInt8]]) {
        let P = (D * pct + 99) / 100
        let shardSize = packetSize + 16

        var data: [[UInt8]] = []
        for i in 0..<D {
            let flags: UInt8 = (i == 0 ? 0x04 : 0) | (i == D - 1 ? 0x02 : 0) | 0x01   // SOF/EOF/PIC
            data.append(datagram(seq: baseSeq &+ UInt16(i), frame: frame, fecIndex: i, dataShards: D,
                                 fecPercentage: pct, flags: flags, multiFecBlocks: 0, video: video(i)))
        }

        let shards = data.map { d -> [UInt8] in
            var s = d; if s.count < shardSize { s += [UInt8](repeating: 0, count: shardSize - s.count) }; return s
        }
        let parityShards = FECFixtureEncoder.videoParity(data: shards, parityShards: P)

        let videoOffset = dataOffset + 16
        var parity: [[UInt8]] = []
        for p in 0..<P {
            let payload = Array(parityShards[p][videoOffset ..< shardSize])
            parity.append(datagram(seq: baseSeq &+ UInt16(D + p), frame: frame, fecIndex: D + p,
                                    dataShards: D, fecPercentage: pct, flags: 0, multiFecBlocks: 0, video: payload))
        }
        return (data, parity)
    }

    private func expectedFrameBytes(dataShards D: Int) -> [UInt8] { (0..<D).flatMap { video($0) } }

    @Test func assemblesFrameWithNoLoss() async throws {
        let D = 4, pct = 50
        let (data, _) = try buildFrame(frame: 1, dataShards: D, fecPercentage: pct, baseSeq: 100)
        let asm = VideoFrameAssembler(packetSize: packetSize)

        var frame: AssembledFrame?
        for d in data { if let f = try asm.ingest(d) { frame = f } }

        let f = try #require(frame)
        #expect(f.frameIndex == 1)
        #expect(!f.recovered)
        #expect(f.data == expectedFrameBytes(dataShards: D))
    }

    @Test func recoversDroppedDataShardFromParity() async throws {
        let D = 4, pct = 50
        let (data, parity) = try buildFrame(frame: 7, dataShards: D, fecPercentage: pct, baseSeq: 200)
        let asm = VideoFrameAssembler(packetSize: packetSize)

        var frame: AssembledFrame?
        for i in [0, 1, 3] { if let f = try asm.ingest(data[i]) { frame = f } }
        #expect(frame == nil)
        if let f = try asm.ingest(parity[0]) { frame = f }

        let f = try #require(frame)
        #expect(f.frameIndex == 7)
        #expect(f.recovered)
        #expect(f.data == expectedFrameBytes(dataShards: D))
    }

    @Test func newerFrameSupersedesIncompleteOlder() async throws {
        let D = 4, pct = 50
        let (older, _) = try buildFrame(frame: 1, dataShards: D, fecPercentage: pct, baseSeq: 10)
        let (newer, _) = try buildFrame(frame: 2, dataShards: D, fecPercentage: pct, baseSeq: 100)
        let asm = VideoFrameAssembler(packetSize: packetSize)

        _ = try asm.ingest(older[0]); _ = try asm.ingest(older[1])
        var frame: AssembledFrame?
        for d in newer { if let f = try asm.ingest(d) { frame = f } }

        let f = try #require(frame)
        #expect(f.frameIndex == 2)
        #expect(f.data == expectedFrameBytes(dataShards: D))
    }

    @Test func tracksEmittedRecoveredAndLostFrames() async throws {
        let D = 4, pct = 50
        let asm = VideoFrameAssembler(packetSize: packetSize)

        let (f1, _) = try buildFrame(frame: 1, dataShards: D, fecPercentage: pct, baseSeq: 10)
        for d in f1 { _ = try asm.ingest(d) }

        let (f3, p3) = try buildFrame(frame: 3, dataShards: D, fecPercentage: pct, baseSeq: 100)
        for i in [0, 1, 3] { _ = try asm.ingest(f3[i]) }
        _ = try asm.ingest(p3[0])

        let stats = asm.lossStats()
        #expect(stats.emitted == 2)
        #expect(stats.recovered == 1)
        #expect(stats.lost == 1)
    }

    @Test func tracksLossWhenNewerFrameSupersedesIncompleteOlder() async throws {
        let D = 4, pct = 50
        let asm = VideoFrameAssembler(packetSize: packetSize)

        let (older, _) = try buildFrame(frame: 5, dataShards: D, fecPercentage: pct, baseSeq: 10)
        let (newer, _) = try buildFrame(frame: 6, dataShards: D, fecPercentage: pct, baseSeq: 100)

        _ = try asm.ingest(older[0]); _ = try asm.ingest(older[1])
        for d in newer { _ = try asm.ingest(d) }

        let stats = asm.lossStats()
        #expect(stats.emitted == 1)
        #expect(stats.lost == 1)
    }
}
