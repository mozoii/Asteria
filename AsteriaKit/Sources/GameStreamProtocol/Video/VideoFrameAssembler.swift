import Foundation

/// Reassembled video frame: concatenated encoded bitstream + FEC recovery flag.
public struct AssembledFrame: Sendable, Equatable {
    public let frameIndex: UInt32
    public let data: [UInt8]
    public let recovered: Bool

    public init(frameIndex: UInt32, data: [UInt8], recovered: Bool) {
        self.frameIndex = frameIndex
        self.data = data
        self.recovered = recovered
    }
}

public enum VideoAssemblyError: Error, Equatable {
    case fecRecoveryFailed
    case malformedBlock
}

struct VideoFecBlock {
    let dataShards: Int
    let parityShards: Int
    let shardSize: Int
    let payloadLen: Int
    let dataOffset: Int
    let lowestSeq: UInt16

    private var shards: [[UInt8]?]
    private(set) var receivedData = 0
    private(set) var receivedTotal = 0
    private var dataPayloadLengths: [Int?]

    var total: Int { dataShards + parityShards }
    var isRecoverable: Bool { receivedTotal >= dataShards }
    var hasAllData: Bool { receivedData == dataShards }

    init(packet: RTPVideoPacket, packetSize: Int) {
        self.dataShards = packet.dataShards
        self.parityShards = packet.parityShards
        self.shardSize = packetSize + RTPVideoPacket.nvHeaderSize
        self.payloadLen = packetSize - RTPVideoPacket.nvHeaderSize
        self.dataOffset = packet.hasExtension ? 16 : 12
        self.lowestSeq = packet.sequenceNumber &- UInt16(packet.fecIndex)
        self.shards = [[UInt8]?](repeating: nil, count: dataShards + parityShards)
        self.dataPayloadLengths = [Int?](repeating: nil, count: dataShards)
    }

    mutating func add(packet: RTPVideoPacket, datagram: [UInt8]) {
        let idx = Int(packet.sequenceNumber &- lowestSeq)
        guard idx >= 0, idx < total, shards[idx] == nil else { return }

        var padded = datagram
        if padded.count < shardSize { padded.append(contentsOf: repeatElement(0, count: shardSize - padded.count)) }
        else if padded.count > shardSize { padded.removeLast(padded.count - shardSize) }
        shards[idx] = padded

        receivedTotal += 1
        if idx < dataShards {
            receivedData += 1
            dataPayloadLengths[idx] = max(0, datagram.count - dataOffset - RTPVideoPacket.nvHeaderSize)
        }
    }

    func assemble() throws -> (data: [UInt8], recovered: Bool) {
        guard isRecoverable else { throw VideoAssemblyError.malformedBlock }

        let videoOffset = dataOffset + RTPVideoPacket.nvHeaderSize
        let recovered = !hasAllData

        var buffers = shards.map { $0 ?? [UInt8](repeating: 0, count: shardSize) }
        if recovered {
            let present = shards.map { $0 != nil }
            let recovery = try HostFECRecovery(
                mode: .video(dataShards: dataShards, parityShards: parityShards)
            )
            try recovery.recover(shards: &buffers, present: present, shardSize: shardSize)
        }

        var out = [UInt8]()
        out.reserveCapacity(dataShards * payloadLen)
        for i in 0..<dataShards {
            let len = min(dataPayloadLengths[i] ?? payloadLen, payloadLen)
            out.append(contentsOf: buffers[i][videoOffset ..< videoOffset + len])
        }
        return (out, recovered)
    }
}

public final class VideoFrameAssembler: @unchecked Sendable {
    public struct LossStats: Sendable, Equatable {
        public var emitted = 0
        public var recovered = 0
        public var lost = 0
        public init() {}
    }

    private let packetSize: Int
    private var currentFrame: UInt32?
    private var lastBlockNumber = 0
    private var blocks: [Int: VideoFecBlock] = [:]
    private var emittedFrame: UInt32?
    private var nextExpectedFrame: UInt32?
    private var loss = LossStats()
    private let lock = NSLock()

    public init(packetSize: Int) {
        self.packetSize = packetSize
    }

    public func lossStats() -> LossStats {
        lock.lock(); defer { lock.unlock() }
        return loss
    }

    public func ingest(_ datagram: [UInt8]) throws -> AssembledFrame? {
        lock.lock(); defer { lock.unlock() }
        guard let packet = RTPVideoPacket(parsing: datagram), packet.dataShards > 0 else { return nil }

        // Ignore packets for a frame we've already delivered or moved past.
        if let emitted = emittedFrame, packet.frameIndex <= emitted, packet.frameIndex == currentFrame {
            return nil
        }

        // Switch to a newer frame, abandoning any incomplete older one.
        if currentFrame != packet.frameIndex {
            if let cur = currentFrame, packet.frameIndex < cur { return nil }   // stale/reordered
            if nextExpectedFrame == nil { nextExpectedFrame = packet.frameIndex }   // first committed frame
            currentFrame = packet.frameIndex
            blocks.removeAll(keepingCapacity: true)
            lastBlockNumber = packet.lastFecBlock
        }
        lastBlockNumber = max(lastBlockNumber, packet.lastFecBlock)

        let blockIndex = packet.currentFecBlock
        if blocks[blockIndex] == nil {
            blocks[blockIndex] = VideoFecBlock(packet: packet, packetSize: packetSize)
        }
        blocks[blockIndex]?.add(packet: packet, datagram: datagram)

        return try tryComplete(frameIndex: packet.frameIndex)
    }

    private func tryComplete(frameIndex: UInt32) throws -> AssembledFrame? {
        for b in 0...lastBlockNumber {
            guard let block = blocks[b], block.isRecoverable else { return nil }
        }
        var data = [UInt8]()
        var recovered = false
        for b in 0...lastBlockNumber {
            let (bytes, rec) = try blocks[b]!.assemble()
            data.append(contentsOf: bytes)
            recovered = recovered || rec
        }
        emittedFrame = frameIndex
        let base = nextExpectedFrame ?? frameIndex
        if frameIndex > base { loss.lost += Int(frameIndex - base) }
        nextExpectedFrame = frameIndex + 1
        loss.emitted += 1
        if recovered { loss.recovered += 1 }
        blocks.removeAll(keepingCapacity: true)
        return AssembledFrame(frameIndex: frameIndex, data: data, recovered: recovered)
    }
}
