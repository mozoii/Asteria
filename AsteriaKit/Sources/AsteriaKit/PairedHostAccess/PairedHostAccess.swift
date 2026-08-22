import Foundation
import AsteriaModel
import Discovery
import GameStreamProtocol
import Pairing

public enum PairedHostAccessError: Error, LocalizedError, Equatable {
    case notPaired(profileID: String)
    case missingPinnedCertificate(profileID: String)
    case identity(profileID: String, detail: String)
    case transport(profileID: String, detail: String)
    case request(profileID: String, operation: String, detail: String)

    public var errorDescription: String? {
        switch self {
        case let .notPaired(profileID):
            return "Host Profile \(profileID) is not paired. Pair it before connecting."
        case let .missingPinnedCertificate(profileID):
            return "Host Profile \(profileID) has no pinned certificate. Pair it again."
        case let .identity(profileID, detail):
            return "Couldn't load the identity for Host Profile \(profileID): \(detail)"
        case let .transport(profileID, detail):
            return "Couldn't create access for Host Profile \(profileID): \(detail)"
        case let .request(profileID, operation, detail):
            return "Couldn't \(operation) for Host Profile \(profileID): \(detail)"
        }
    }
}

public struct PairedHostAccess: Sendable {
    typealias TransportFactory = @Sendable (
        _ address: String,
        _ identity: ClientIdentity
    ) throws -> any GameStreamTransport

    public let profile: HostRecord
    let transport: any GameStreamTransport
    let uniqueID: String
    private let client: HostClient

    public init(profile: HostRecord, identities: ClientIdentityVault) throws {
        try self.init(
            profile: profile,
            identities: identities,
            transportFactory: { address, identity in
                try GameStreamHTTPTransport(host: address, identity: identity)
            }
        )
    }

    init(
        profile: HostRecord,
        identities: ClientIdentityVault,
        transportFactory: TransportFactory
    ) throws {
        guard profile.isPaired else {
            throw PairedHostAccessError.notPaired(profileID: profile.id)
        }
        guard let certificate = profile.pinnedCertificate else {
            throw PairedHostAccessError.missingPinnedCertificate(profileID: profile.id)
        }
        let identity: ClientIdentity
        do {
            identity = try identities.load(for: profile.clientFingerprint)
        } catch {
            throw PairedHostAccessError.identity(
                profileID: profile.id,
                detail: error.localizedDescription
            )
        }
        let transport: any GameStreamTransport
        do {
            transport = try transportFactory(profile.address, identity)
        } catch {
            throw PairedHostAccessError.transport(
                profileID: profile.id,
                detail: error.localizedDescription
            )
        }
        transport.setPinnedServerCertificate([UInt8](certificate))
        self.profile = profile
        self.transport = transport
        self.uniqueID = identity.uniqueId
        self.client = HostClient(transport: transport, uniqueId: identity.uniqueId)
    }

    public func apps() async throws -> [GameApp] {
        try await request(operation: "load apps") { try await client.appList() }
    }

    public func serverInfo() async throws -> ServerInfo {
        try await request(operation: "load server information") {
            try ServerInfoParser.parse(try await client.serverInfo())
        }
    }

    public func boxArt(appID: String) async throws -> Data {
        try await request(operation: "load box art") {
            try await client.appAsset(appId: appID)
        }
    }

    public func cancel() async throws -> Bool {
        try await request(operation: "cancel the running app") {
            try await client.cancel()
        }
    }

    public func supportsRuntimeBitrate() async -> Bool {
        await client.supportsRuntimeBitrate()
    }

    func hostClient() -> HostClient {
        client
    }

    private func request<Value: Sendable>(
        operation: String,
        body: () async throws -> Value
    ) async throws -> Value {
        do {
            return try await body()
        } catch let error as PairingError {
            throw error
        } catch {
            throw PairedHostAccessError.request(
                profileID: profile.id,
                operation: operation,
                detail: error.localizedDescription
            )
        }
    }
}
