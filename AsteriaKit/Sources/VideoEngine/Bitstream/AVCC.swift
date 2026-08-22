import Foundation

/// Length-prefixed NAL framing: 4-byte big-endian length followed by NAL data, no start codes. VideoToolbox sample buffer format with `nalUnitHeaderLength = 4`.
public enum AVCC {
    /// Length prefix size baked into the format description (`nalUnitHeaderLength`).
    public static let lengthPrefixSize = 4

    /// Encode NALs as length(4, big-endian) || payload. Empty NALs are skipped.
    public static func encode(_ nals: [ArraySlice<UInt8>]) -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(nals.reduce(0) { $0 + $1.count + lengthPrefixSize })
        for nal in nals where !nal.isEmpty {
            let len = UInt32(nal.count)
            out.append(UInt8((len >> 24) & 0xFF))
            out.append(UInt8((len >> 16) & 0xFF))
            out.append(UInt8((len >> 8) & 0xFF))
            out.append(UInt8(len & 0xFF))
            out.append(contentsOf: nal)
        }
        return out
    }
}
