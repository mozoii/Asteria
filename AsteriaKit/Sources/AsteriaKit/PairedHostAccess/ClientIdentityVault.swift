import Foundation
import AsteriaCore
import AsteriaModel
import Pairing

public enum ClientIdentityVaultError: Error, LocalizedError, Equatable {
    case missingFingerprint
    case missingIdentity(ClientFingerprint)

    public var errorDescription: String? {
        switch self {
        case .missingFingerprint:
            return "The Host Profile has no client fingerprint. Forget and pair it again."
        case let .missingIdentity(fingerprint):
            return "The client identity for fingerprint \(fingerprint) is missing. "
                + "Forget and pair the Host Profile again."
        }
    }
}

public struct ClientIdentityVault: Sendable {
    private let secretStore: any SecretStore

    public init(secretStore: any SecretStore) {
        self.secretStore = secretStore
    }

    public func load(for fingerprint: ClientFingerprint?) throws -> ClientIdentity {
        guard let fingerprint else { throw ClientIdentityVaultError.missingFingerprint }
        guard let data = try secretStore.data(forKey: key(for: fingerprint)),
              let pem = String(data: data, encoding: .utf8) else {
            throw ClientIdentityVaultError.missingIdentity(fingerprint)
        }
        return try ClientIdentity.load(fromPEM: pem)
    }

    public func create() throws -> ClientIdentity {
        try ClientIdentity.createKeychainBacked()
    }

    public func save(_ identity: ClientIdentity) throws {
        try secretStore.set(
            Data(identity.combinedPEM.utf8),
            forKey: key(for: identity.fingerprint)
        )
    }

    private func key(for fingerprint: ClientFingerprint) -> String {
        "client-identity-pem.\(fingerprint.rawValue)"
    }
}
