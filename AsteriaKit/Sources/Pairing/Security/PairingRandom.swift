import Foundation
import Security

public enum PairingRandom {
    static func bytes(_ count: Int) -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &buffer)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed: \(status)")
        return buffer
    }

    public static func pin(digits: Int = 4) -> String {
        var out = String()
        out.reserveCapacity(digits)
        for _ in 0..<digits { out.append(Character(String(uniformDigit()))) }
        return out
    }

    private static func uniformDigit() -> UInt8 {
        while true {
            let b = bytes(1)[0]
            if b < 250 { return b % 10 }   // 250 = floor(256/10)*10; reject the biased tail
        }
    }
}

/// Constant-time comparison to prevent timing-based attacks on hash verification.
func constantTimeEquals(_ a: [UInt8], _ b: [UInt8]) -> Bool {
    guard a.count == b.count else { return false }
    var diff: UInt8 = 0
    for i in a.indices { diff |= a[i] ^ b[i] }
    return diff == 0
}
