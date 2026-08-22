import Foundation

/// GameStream control-stream message types for gen7 encrypted protocol.
public enum ControlMessage {
    public typealias Message = (type: UInt16, payload: [UInt8])

    public static let startA: Message = (0x0302, [0, 0])
    public static let startB: Message = (0x0307, [0])
    /// Periodic keepalive sent every 100 ms.
    public static let ping: Message = (0x0200, [0x04, 0, 0, 0, 0, 0, 0, 0])

    /// Request a keyframe (IDR). Host treats as such after streaming begins.
    public static let requestIdr: Message = (0x0302, [0, 0])

    /// Reference-frame invalidation (HEVC LTR recovery): frames `first…last` were lost.
    public static func invalidateReferenceFrames(first: UInt32, last: UInt32) -> Message {
        var p = [UInt8](); p.reserveCapacity(24)
        p += le32(first); p += le32(0); p += le32(last); p += le32(0); p += le32(0); p += le32(0)
        return (0x0301, p)
    }

    private static func le32(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
    }

    /// ENet channel IDs.
    public static let channelGeneric: UInt8 = 0x00
    public static let channelUrgent: UInt8 = 0x01
    public static let channelCount: Int = 0x30

    public static let pingIntervalMs: UInt64 = 100
}
