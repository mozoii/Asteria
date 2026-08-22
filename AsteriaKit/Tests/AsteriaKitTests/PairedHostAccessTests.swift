import Foundation
import Testing
@testable import AsteriaKit

@Suite("Paired Host Access")
struct PairedHostAccessTests {
    @Test("paired Host Profile establishes authenticated host access")
    func establishesAccess() async throws {
        let secrets = InMemorySecretStore()
        let identities = ClientIdentityVault(secretStore: secrets)
        let identity = try identities.create()
        try identities.save(identity)
        var profile = HostRecord(
            id: "living-room",
            name: "Living Room",
            address: "192.168.1.20"
        )
        profile.markPaired(
            pinnedCertificate: Data([0x01, 0x02, 0x03]),
            clientFingerprint: identity.fingerprint
        )
        let transport = RecordingHostTransport(
            response: Data(#"<root status_code="200"><cancel>1</cancel></root>"#.utf8)
        )

        let access = try PairedHostAccess(
            profile: profile,
            identities: identities,
            transportFactory: { _, _ in transport }
        )

        #expect(try await access.cancel())
        #expect(transport.pinnedCertificate == [0x01, 0x02, 0x03])
        #expect(transport.requestPath == "cancel")
    }

    @Test("server certificate mismatch remains an actionable verification failure")
    func preservesServerVerificationFailure() async throws {
        let secrets = InMemorySecretStore()
        let identities = ClientIdentityVault(secretStore: secrets)
        let identity = try identities.create()
        try identities.save(identity)
        var profile = HostRecord(
            id: "living-room",
            name: "Living Room",
            address: "192.168.1.20"
        )
        profile.markPaired(
            pinnedCertificate: Data([0x01, 0x02, 0x03]),
            clientFingerprint: identity.fingerprint
        )
        let access = try PairedHostAccess(
            profile: profile,
            identities: identities,
            transportFactory: { _, _ in VerificationFailureHostTransport() }
        )

        await #expect(throws: PairingError.serverVerificationFailed) {
            try await access.apps()
        }
    }
}

private struct VerificationFailureHostTransport: GameStreamTransport {
    func get(secure: Bool, path: String, query: [URLQueryItem]) async throws -> Data {
        throw PairingError.serverVerificationFailed
    }
}

private final class RecordingHostTransport: GameStreamTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let response: Data
    private var pinned: [UInt8]?
    private var path: String?

    init(response: Data) {
        self.response = response
    }

    var pinnedCertificate: [UInt8]? { lock.withLock { pinned } }
    var requestPath: String? { lock.withLock { path } }

    func get(secure: Bool, path: String, query: [URLQueryItem]) async throws -> Data {
        lock.withLock { self.path = path }
        return response
    }

    func setPinnedServerCertificate(_ der: [UInt8]?) {
        lock.withLock { pinned = der }
    }
}
