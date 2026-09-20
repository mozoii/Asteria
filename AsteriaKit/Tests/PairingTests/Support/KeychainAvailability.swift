import Foundation
import Security

/// Whether this machine's keychain will accept and return a generated key item. Sandboxed or unsigned
/// test hosts can refuse (`errSecMissingEntitlement`), so identity suites skip instead of failing there.
///
/// On iOS this is also the mechanical check that the data-protection keychain can back the mutual-TLS
/// identity — the question the macOS curl workaround exists to answer for the file-based keychain.
enum KeychainAvailability {
    static let isWritable: Bool = {
        let tag = Data("io.github.mozoii.asteria.tests.probe.\(UUID().uuidString)".utf8)
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey([
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits: 2048,
        ] as CFDictionary, &error) else { return false }
        let status = SecItemAdd([
            kSecClass: kSecClassKey,
            kSecValueRef: key,
            kSecAttrApplicationTag: tag,
        ] as CFDictionary, nil)
        defer {
            SecItemDelete([kSecClass: kSecClassKey, kSecAttrApplicationTag: tag] as CFDictionary)
        }
        return status == errSecSuccess
    }()
}
