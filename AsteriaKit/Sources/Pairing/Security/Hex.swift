import Foundation

/// Hex coding (encode/decode) for wire protocol.
public enum Hex {
    public static func encode(_ bytes: [UInt8], uppercase: Bool = false) -> String {
        let format = uppercase ? "%02X" : "%02x"
        return bytes.map { String(format: format, $0) }.joined()
    }

    public static func decode(_ string: String) -> [UInt8]? {
        let chars = Array(string)
        guard chars.count.isMultiple(of: 2) else { return nil }
        var out = [UInt8]()
        out.reserveCapacity(chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let hi = chars[i].hexDigitValue, let lo = chars[i + 1].hexDigitValue else { return nil }
            out.append(UInt8(hi << 4 | lo))
            i += 2
        }
        return out
    }
}
