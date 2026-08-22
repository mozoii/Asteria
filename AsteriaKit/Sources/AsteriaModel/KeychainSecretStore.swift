import Foundation
import Security

public enum KeychainError: Error, LocalizedError, CustomStringConvertible {
    case unexpectedStatus(OSStatus)

    public var status: OSStatus {
        switch self { case let .unexpectedStatus(status): return status }
    }
    public var description: String {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown error"
        return "keychain error \(status): \(message)"
    }
    public var errorDescription: String? { description }
}

/// Keychain-backed `SecretStore` (generic-password items, scoped by service).
public struct KeychainSecretStore: SecretStore {
    public let service: String
    public init(service: String) { self.service = service }

    private func baseQuery(_ key: String) -> [String: Any] {
        // The classic file-based keychain is deliberate: the data-protection keychain requires
        // entitlements (keychain-access-groups) that ad-hoc signed builds cannot carry (errSecMissingEntitlement).
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: key]
    }

    public func data(forKey key: String) throws -> Data? {
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess: return result as? Data
        case errSecItemNotFound: return nil
        default: throw KeychainError.unexpectedStatus(status)
        }
    }

    public func set(_ data: Data, forKey key: String) throws {
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let updateStatus = SecItemUpdate(baseQuery(key) as CFDictionary, attributes as CFDictionary)
        switch updateStatus {
        case errSecSuccess: return
        case errSecItemNotFound:
            var addQuery = baseQuery(key)
            addQuery.merge(attributes) { _, new in new }
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.unexpectedStatus(addStatus) }
        default:
            throw KeychainError.unexpectedStatus(updateStatus)
        }
    }

    public func removeValue(forKey key: String) throws {
        let status = SecItemDelete(baseQuery(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}
