import Foundation

/// NAL categories: parameter sets and keyframe/non-keyframe slices. Parameter sets feed `CMVideoFormatDescription`.
public enum NALCategory: Equatable, Sendable {
    case vps, sps, pps
    case idr        // IDR (H.264) / IRAP keyframe (HEVC BLA/IDR/CRA) VCL slice
    case nonIdr     // non-keyframe VCL slice
    case other      // SEI, AUD, filler, etc.
}

/// H.264 NAL type from first byte: `nal_unit_type(5)` bits (lower 5 bits).
public enum H264NAL {
    public static func type(of nal: ArraySlice<UInt8>) -> UInt8 {
        guard let first = nal.first else { return 0xFF }
        return first & 0x1F
    }

    public static func category(of nal: ArraySlice<UInt8>) -> NALCategory {
        switch type(of: nal) {
        case 7:  return .sps
        case 8:  return .pps
        case 5:  return .idr      // IDR slice
        case 1:  return .nonIdr   // non-IDR coded slice
        default: return .other    // SEI(6), AUD(9), filler, etc.
        }
    }
}

/// HEVC NAL type from first byte: bits 1–6 (shifted right by 1, masked 0x3F).
public enum HEVCNAL {
    public static func type(of nal: ArraySlice<UInt8>) -> UInt8 {
        guard let first = nal.first else { return 0xFF }
        return (first >> 1) & 0x3F
    }

    public static func category(of nal: ArraySlice<UInt8>) -> NALCategory {
        let t = type(of: nal)
        switch t {
        case 32: return .vps
        case 33: return .sps
        case 34: return .pps
        case 0...31:
            // VCL range. IRAP keyframes (BLA_W_LP … CRA_NUT) are types 16–23.
            return (16...23).contains(t) ? .idr : .nonIdr
        default: return .other   // AUD(35), EOS/EOB, SEI(39/40), etc.
        }
    }
}
