import Foundation
import CommonCrypto

public enum AESECBError: Error, Equatable {
    case invalidBlockSize
    case cryptFailed(Int32)
}

/// AES-128 in ECB mode, no padding. Wraps CommonCrypto (CryptoKit lacks ECB).
public enum AESECB {
    public static func encrypt(_ data: [UInt8], key: [UInt8]) throws -> [UInt8] {
        try crypt(data, key: key, operation: CCOperation(kCCEncrypt))
    }

    public static func decrypt(_ data: [UInt8], key: [UInt8]) throws -> [UInt8] {
        try crypt(data, key: key, operation: CCOperation(kCCDecrypt))
    }

    private static func crypt(_ data: [UInt8], key: [UInt8], operation: CCOperation) throws -> [UInt8] {
        guard data.count % kCCBlockSizeAES128 == 0, !data.isEmpty else { throw AESECBError.invalidBlockSize }
        var output = [UInt8](repeating: 0, count: data.count)
        var moved = 0
        let status = key.withUnsafeBytes { keyPtr in
            data.withUnsafeBytes { dataPtr in
                output.withUnsafeMutableBytes { outPtr in
                    CCCrypt(
                        operation,
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionECBMode),
                        keyPtr.baseAddress, key.count,
                        nil,
                        dataPtr.baseAddress, data.count,
                        outPtr.baseAddress, outPtr.count,
                        &moved
                    )
                }
            }
        }
        guard status == Int32(kCCSuccess) else { throw AESECBError.cryptFailed(status) }
        return Array(output.prefix(moved))
    }
}
