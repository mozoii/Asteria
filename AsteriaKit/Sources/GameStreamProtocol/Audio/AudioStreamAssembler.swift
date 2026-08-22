import Foundation

/// One recovered Opus packet: sequence number, payload bytes, and recovery status.
public struct AudioOpusPacket: Sendable, Equatable {
    public let sequenceNumber: UInt16
    public let data: [UInt8]
    public let recovered: Bool

    public init(sequenceNumber: UInt16, data: [UInt8], recovered: Bool) {
        self.sequenceNumber = sequenceNumber
        self.data = data
        self.recovered = recovered
    }
}

public enum AudioAssemblyError: Error, Equatable {
    case fecRecoveryFailed
}

struct AudioFecBlock {
    static let dataShards = 4
    static let parityShards = 2
    static let totalShards = dataShards + parityShards

    let baseSequenceNumber: UInt16
    private(set) var blockSize: Int

    private var shards: [[UInt8]?]
    private(set) var receivedData = 0
    private(set) var receivedTotal = 0

    var hasAllData: Bool { receivedData == Self.dataShards }
    var isRecoverable: Bool { receivedTotal >= Self.dataShards }

    init(baseSequenceNumber: UInt16, blockSize: Int) {
        self.baseSequenceNumber = baseSequenceNumber
        self.blockSize = blockSize
        self.shards = [[UInt8]?](repeating: nil, count: Self.totalShards)
    }

    mutating func addData(sequenceNumber: UInt16, payload: [UInt8]) {
        let idx = Int(sequenceNumber &- baseSequenceNumber)
        guard idx >= 0, idx < Self.dataShards else { return }
        add(idx: idx, payload: payload, isData: true)
    }

    mutating func addParity(fecShardIndex: UInt8, payload: [UInt8]) {
        let idx = Self.dataShards + Int(fecShardIndex)
        guard idx >= Self.dataShards, idx < Self.totalShards else { return }
        add(idx: idx, payload: payload, isData: false)
    }

    private mutating func add(idx: Int, payload: [UInt8], isData: Bool) {
        guard shards[idx] == nil, payload.count == blockSize else { return }
        shards[idx] = payload
        receivedTotal += 1
        if isData { receivedData += 1 }
    }

    func assemble(using recovery: HostFECRecovery) throws -> [AudioOpusPacket] {
        let recoveredSlots = shards.map { $0 == nil }
        var out: [AudioOpusPacket] = []
        out.reserveCapacity(Self.dataShards)

        if hasAllData {
            for i in 0..<Self.dataShards {
                out.append(AudioOpusPacket(sequenceNumber: baseSequenceNumber &+ UInt16(i),
                                           data: shards[i]!, recovered: false))
            }
            return out
        }

        var buffers = shards.map { $0 ?? [UInt8](repeating: 0, count: blockSize) }
        let present = shards.map { $0 != nil }
        do {
            try recovery.recover(shards: &buffers, present: present, shardSize: blockSize)
        } catch {
            throw AudioAssemblyError.fecRecoveryFailed
        }
        for i in 0..<Self.dataShards {
            out.append(AudioOpusPacket(sequenceNumber: baseSequenceNumber &+ UInt16(i),
                                       data: buffers[i], recovered: recoveredSlots[i]))
        }
        return out
    }
}

/// Reassembles audio RTP into ordered Opus packets, emitting each packet as soon as it is next in sequence
/// rather than holding it for its FEC block; a still-missing `nextSeq` skips forward after `outOfSequenceLead` packets.
public final class AudioStreamAssembler: @unchecked Sendable {
    private static let pendingBlockLimit = 8
    private static let dataShards = UInt16(AudioFecBlock.dataShards)
    /// How far ahead buffered packets may run before a still-missing `nextSeq` is skipped.
    private static let outOfSequenceLead = AudioFecBlock.dataShards

    private let recovery: HostFECRecovery
    private var blocks: [UInt16: AudioFecBlock] = [:]
    private var pending: [UInt16: (data: [UInt8], recovered: Bool)] = [:]
    private var nextSeq: UInt16?
    private var highestSeq: UInt16?
    private let lock = NSLock()

    public init() throws {
        self.recovery = try HostFECRecovery(mode: .audio)
    }

    /// Ingest one datagram; returns the packets that became emittable in sequence order (possibly empty).
    public func ingest(_ datagram: [UInt8]) -> [AudioOpusPacket] {
        lock.lock(); defer { lock.unlock() }
        guard let packet = RTPAudioPacket(parsing: datagram) else { return [] }
        register(packet)
        return drain()
    }

    private func register(_ packet: RTPAudioPacket) {
        let baseSeq: UInt16
        let blockSize: Int
        if packet.isData {
            baseSeq = blockBase(packet.sequenceNumber)
            blockSize = packet.payload.count
        } else if packet.isFec, let header = packet.fecHeader, let parity = packet.parity {
            guard header.baseSequenceNumber % Self.dataShards == 0 else { return }
            baseSeq = header.baseSequenceNumber
            blockSize = parity.count
        } else {
            return
        }

        // Ignore late shards for a block we've already emitted or skipped past entirely.
        if let next = nextSeq, !isBefore16(next, baseSeq &+ Self.dataShards) { return }

        if blocks[baseSeq] == nil {
            blocks[baseSeq] = AudioFecBlock(baseSequenceNumber: baseSeq, blockSize: blockSize)
            evictIfNeeded()
        }
        guard blocks[baseSeq] != nil else { return }

        if packet.isData {
            blocks[baseSeq]!.addData(sequenceNumber: packet.sequenceNumber, payload: packet.payload)
            stage(seq: packet.sequenceNumber, data: packet.payload, recovered: false)
        } else if let header = packet.fecHeader, let parity = packet.parity {
            blocks[baseSeq]!.addParity(fecShardIndex: header.fecShardIndex, payload: parity)
        }
    }

    private func stage(seq: UInt16, data: [UInt8], recovered: Bool) {
        if nextSeq == nil { nextSeq = blockBase(seq) }
        if let next = nextSeq, isBefore16(seq, next) { return }
        if pending[seq] == nil { pending[seq] = (data, recovered) }
        if highestSeq == nil || isBefore16(highestSeq!, seq) { highestSeq = seq }
    }

    private func drain() -> [AudioOpusPacket] {
        guard var next = nextSeq else { return [] }
        var out: [AudioOpusPacket] = []
        while true {
            if let entry = pending.removeValue(forKey: next) {
                out.append(AudioOpusPacket(sequenceNumber: next, data: entry.data, recovered: entry.recovered))
                next = next &+ 1
                continue
            }
            if recover(base: blockBase(next)) { continue }
            guard let highest = highestSeq, seqDistance(from: next, to: highest) >= Self.outOfSequenceLead,
                  let smallest = pending.keys.min(by: { isBefore16($0, $1) }) else { break }
            next = smallest
        }
        nextSeq = next
        return out
    }

    /// Reconstruct `base`'s block from parity when recoverable, staging the packets it produces. Returns
    /// whether anything was staged (i.e. the caller should retry the drain).
    private func recover(base: UInt16) -> Bool {
        guard let block = blocks[base], block.isRecoverable, !block.hasAllData else { return false }
        blocks[base] = nil
        guard let packets = try? block.assemble(using: recovery) else { return false }
        for p in packets { stage(seq: p.sequenceNumber, data: p.data, recovered: p.recovered) }
        return true
    }

    private func blockBase(_ seq: UInt16) -> UInt16 { (seq / Self.dataShards) &* Self.dataShards }
    private func seqDistance(from a: UInt16, to b: UInt16) -> Int { Int(Int16(bitPattern: b &- a)) }

    private func evictIfNeeded() {
        while blocks.count > Self.pendingBlockLimit {
            guard let oldest = blocks.keys.min(by: { isBefore16($0, $1) }) else { return }
            blocks[oldest] = nil
        }
    }
}

/// 16-bit sequence-number ordering with wraparound: true when `a` precedes `b` in the sequence space.
func isBefore16(_ a: UInt16, _ b: UInt16) -> Bool { Int16(bitPattern: a &- b) < 0 }
