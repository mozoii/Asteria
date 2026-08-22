import Foundation

/// Parsed RTP audio packet. Data packets (type 97) carry Opus; FEC packets (type 127) carry AUDIO_FEC_HEADER + parity bytes.
public struct RTPAudioPacket: Sendable, Equatable {
    public let headerByte: UInt8
    public let packetType: UInt8
    public let sequenceNumber: UInt16
    public let timestamp: UInt32
    public let ssrc: UInt32

    /// Bytes after the RTP header (Opus payload for data packets, AUDIO_FEC_HEADER + parity for FEC).
    public let payload: [UInt8]

    public static let rtpHeaderSize = 12
    public static let fecHeaderSize = 12

    public static let payloadTypeData: UInt8 = 97
    public static let payloadTypeFec: UInt8 = 127

    public var isData: Bool { packetType == Self.payloadTypeData }
    public var isFec: Bool { packetType == Self.payloadTypeFec }

    public init?(parsing bytes: [UInt8]) {
        guard bytes.count >= Self.rtpHeaderSize else { return nil }
        self.headerByte = bytes[0]
        self.packetType = bytes[1]
        self.sequenceNumber = Self.beU16(bytes, 2)
        self.timestamp = Self.beU32(bytes, 4)
        self.ssrc = Self.beU32(bytes, 8)
        self.payload = Array(bytes[Self.rtpHeaderSize...])
    }

    /// Decoded FEC header (FEC packets only). Multi-byte fields are big-endian.
    public var fecHeader: AudioFecHeader? {
        guard isFec, payload.count >= Self.fecHeaderSize else { return nil }
        return AudioFecHeader(
            fecShardIndex: payload[0],
            payloadType: payload[1],
            baseSequenceNumber: Self.beU16(payload, 2),
            baseTimestamp: Self.beU32(payload, 4),
            ssrc: Self.beU32(payload, 8)
        )
    }

    /// The parity bytes of a FEC packet (everything after the `AUDIO_FEC_HEADER`).
    public var parity: [UInt8]? {
        guard isFec, payload.count >= Self.fecHeaderSize else { return nil }
        return Array(payload[Self.fecHeaderSize...])
    }

    private static func beU16(_ b: [UInt8], _ i: Int) -> UInt16 { UInt16(b[i]) << 8 | UInt16(b[i + 1]) }
    private static func beU32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3])
    }
}

/// AUDIO_FEC_HEADER from audio FEC packet: FEC block identity + this packet's parity-shard index.
public struct AudioFecHeader: Sendable, Equatable {
    public let fecShardIndex: UInt8
    public let payloadType: UInt8
    public let baseSequenceNumber: UInt16
    public let baseTimestamp: UInt32
    public let ssrc: UInt32
}
