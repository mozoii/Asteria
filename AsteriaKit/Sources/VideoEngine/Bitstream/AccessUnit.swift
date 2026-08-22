import Foundation

/// NAL-based codecs (H.264 / HEVC). AV1 uses OBU framing and is handled separately.
public enum NALCodec: Sendable, Equatable {
    case h264, hevc
}

/// Split access unit: parameter sets for `CMVideoFormatDescription`, sample NALs (VCL/SEI) for `CMSampleBuffer`, and keyframe flag.
public struct SplitAccessUnit: Equatable, Sendable {
    public let parameterSets: [ArraySlice<UInt8>]   // VPS/SPS/PPS, stream order
    public let sampleNALs: [ArraySlice<UInt8>]      // VCL (+ SEI/AUD), stream order
    public let isKeyframe: Bool
}

public enum AccessUnit {
    /// Split GameStream frame by NAL category; strip Sunshine per-frame header first. IDR/IRAP slice presence marks keyframe.
    public static func split(_ frame: [UInt8], codec: NALCodec) -> SplitAccessUnit {
        var parameterSets: [ArraySlice<UInt8>] = []
        var sampleNALs: [ArraySlice<UInt8>] = []
        var isKeyframe = false

        for nal in AnnexB.nalUnits(in: bitstream(frame)) {
            let category = codec == .h264 ? H264NAL.category(of: nal) : HEVCNAL.category(of: nal)
            switch category {
            case .vps, .sps, .pps:
                parameterSets.append(nal)
            case .idr:
                isKeyframe = true
                sampleNALs.append(nal)
            case .nonIdr, .other:
                sampleNALs.append(nal)
            }
        }

        return SplitAccessUnit(parameterSets: parameterSets, sampleNALs: sampleNALs, isKeyframe: isKeyframe)
    }

    /// Strip Sunshine per-frame header. Look for the 4-byte start code `00 00 00 01` within a short window; skip to it and discard the header. Header bytes may contain `00 00 01` falsely resembling a start code.
    static func bitstream(_ frame: [UInt8]) -> [UInt8] {
        let window = min(frame.count, 24)
        var i = 0
        while i + 4 <= window {
            if frame[i] == 0, frame[i + 1] == 0, frame[i + 2] == 0, frame[i + 3] == 1 {
                return i == 0 ? frame : Array(frame[i...])
            }
            i += 1
        }
        return frame
    }
}
