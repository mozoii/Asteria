import Foundation

/// Parsed RTP video packet: RTP header (big-endian, ±4 bytes) + NV header (little-endian).
public struct RTPVideoPacket: Sendable, Equatable {
    public let headerByte: UInt8
    public let packetType: UInt8
    public let sequenceNumber: UInt16
    public let timestamp: UInt32
    public let ssrc: UInt32

    public let streamPacketIndex: UInt32
    public let frameIndex: UInt32
    public let flags: UInt8
    public let extraFlags: UInt8
    public let multiFecFlags: UInt8
    public let multiFecBlocks: UInt8
    public let fecInfo: UInt32

    public static let flagExtension: UInt8 = 0x10
    public static let flagContainsPicData: UInt8 = 0x01
    public static let flagEndOfFrame: UInt8 = 0x02
    public static let flagStartOfFrame: UInt8 = 0x04

    public static let rtpHeaderSize = 12
    public static let nvHeaderSize = 16

    /// This packet's position within its FEC block (data shards `[0, dataShards)`, then parity).
    public var fecIndex: Int { Int((fecInfo & 0x003FF000) >> 12) }
    /// Number of data shards in this FEC block.
    public var dataShards: Int { Int((fecInfo & 0xFFC00000) >> 22) }
    /// Requested parity overhead, as a percentage of the data shards.
    public var fecPercentage: Int { Int((fecInfo & 0x00000FF0) >> 4) }
    /// Derived parity-shard count: ceil(dataShards * fecPercentage / 100).
    public var parityShards: Int { (dataShards * fecPercentage + 99) / 100 }
    /// This packet's multi-FEC block index within the frame, and the frame's last block index.
    public var currentFecBlock: Int { Int((multiFecBlocks >> 4) & 0x3) }
    public var lastFecBlock: Int { Int((multiFecBlocks >> 6) & 0x3) }

    public var hasExtension: Bool { headerByte & Self.flagExtension != 0 }
    public var containsPicData: Bool { flags & Self.flagContainsPicData != 0 }
    public var isFrameStart: Bool { flags & Self.flagStartOfFrame != 0 }
    public var isFrameEnd: Bool { flags & Self.flagEndOfFrame != 0 }
    /// A parity shard (fecIndex at or beyond the data-shard count).
    public var isParity: Bool { fecIndex >= dataShards }

    public init?(parsing bytes: [UInt8]) {
        guard bytes.count >= Self.rtpHeaderSize else { return nil }
        let headerByte = bytes[0]
        let dataOffset = Self.rtpHeaderSize + ((headerByte & Self.flagExtension != 0) ? 4 : 0)
        guard bytes.count >= dataOffset + Self.nvHeaderSize else { return nil }

        self.headerByte = headerByte
        self.packetType = bytes[1]
        self.sequenceNumber = Self.beU16(bytes, 2)
        self.timestamp = Self.beU32(bytes, 4)
        self.ssrc = Self.beU32(bytes, 8)

        let n = dataOffset
        self.streamPacketIndex = Self.leU32(bytes, n + 0)
        self.frameIndex = Self.leU32(bytes, n + 4)
        self.flags = bytes[n + 8]
        self.extraFlags = bytes[n + 9]
        self.multiFecFlags = bytes[n + 10]
        self.multiFecBlocks = bytes[n + 11]
        self.fecInfo = Self.leU32(bytes, n + 12)

    }

    private static func beU16(_ b: [UInt8], _ i: Int) -> UInt16 { UInt16(b[i]) << 8 | UInt16(b[i + 1]) }
    private static func beU32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3])
    }
    private static func leU32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
    }
}
