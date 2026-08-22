import Foundation

/// Annex B byte-stream framing for H.264 / HEVC: split into NALs delimited by start codes (`00 00 01` or `00 00 00 01`), then convert to AVCC for VideoToolbox.
public enum AnnexB {
    /// Split Annex B stream into NAL units, stripping start codes. Bytes before first start code and empty NALs from consecutive start codes are skipped.
    public static func nalUnits(in bytes: [UInt8]) -> [ArraySlice<UInt8>] {
        var result: [ArraySlice<UInt8>] = []
        let n = bytes.count
        var i = 0
        var nalStart: Int? = nil          // first payload byte of the NAL currently being scanned

        while i + 2 < n {
            // A start code is the 3-byte prefix `00 00 01`, optionally preceded by a zero byte
            // (the 4-byte form `00 00 00 01`). Both delimit a NAL; the extra leading zero is framing.
            if bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 1 {
                let startCodeBegin = (i > 0 && bytes[i - 1] == 0) ? i - 1 : i
                if let s = nalStart, startCodeBegin > s {
                    result.append(bytes[s ..< startCodeBegin])
                }
                i += 3
                nalStart = i
            } else {
                i += 1
            }
        }

        if let s = nalStart, s < n {
            result.append(bytes[s ..< n])
        }
        return result
    }
}
