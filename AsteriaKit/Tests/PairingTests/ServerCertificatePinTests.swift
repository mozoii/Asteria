import Foundation
import Testing
@testable import Pairing

/// The pin policy both transports share: macOS hands the hash to curl, iOS compares the leaf in a
/// URLSession trust challenge. These run on every platform so the two can't drift apart.
@Suite("Server certificate pin")
struct ServerCertificatePinTests {
    @Test("server certificate pin requires an exact DER match")
    func serverCertificatePinMatch() {
        let pinned = Data([0x30, 0x82, 0x01])

        #expect(ServerCertificatePin.matches(presented: pinned, pinned: pinned))
        #expect(!ServerCertificatePin.matches(presented: Data([0x30, 0x82, 0x02]), pinned: pinned))
        #expect(!ServerCertificatePin.matches(presented: nil, pinned: pinned))
        #expect(!ServerCertificatePin.matches(presented: pinned, pinned: nil))
    }

    @Test("the public-key pin hash is a stable SHA-256 of the certificate's SPKI")
    func pinHashIsStableSha256() throws {
        let identity = try ClientIdentity.generate()

        let first = try #require(ServerCertificatePin.publicKeyPinHash(for: Data(identity.certificateDER)))
        let second = ServerCertificatePin.publicKeyPinHash(for: Data(identity.certificateDER))

        #expect(first == second)
        // base64 of a SHA-256 digest is 44 characters.
        #expect(first.count == 44)
    }

    @Test("a different certificate hashes to a different pin")
    func pinHashDistinguishesCertificates() throws {
        let first = try #require(
            ServerCertificatePin.publicKeyPinHash(for: Data(try ClientIdentity.generate().certificateDER)))
        let second = try #require(
            ServerCertificatePin.publicKeyPinHash(for: Data(try ClientIdentity.generate().certificateDER)))

        #expect(first != second)
    }

    @Test("the trust decision accepts only the exact pinned leaf")
    func trustDecisionAcceptsPinnedLeafOnly() {
        let pinned = Data([0xAA, 0xBB, 0xCC])

        #expect(ServerCertificatePin.decide(presentedLeaf: pinned, pinned: pinned) == .accept)
        #expect(ServerCertificatePin.decide(presentedLeaf: Data([0xAA, 0xBB, 0xCD]), pinned: pinned)
            == .rejectMismatch)
    }

    @Test("an unpinned challenge is refused rather than trusted")
    func trustDecisionFailsClosedWithoutAPin() {
        #expect(ServerCertificatePin.decide(presentedLeaf: Data([0xAA]), pinned: nil) == .rejectUnpinned)
        #expect(ServerCertificatePin.decide(presentedLeaf: nil, pinned: nil) == .rejectUnpinned)
    }

    @Test("a pinned challenge presenting no certificate is refused")
    func trustDecisionRefusesMissingLeaf() {
        #expect(ServerCertificatePin.decide(presentedLeaf: nil, pinned: Data([0xAA])) == .rejectMismatch)
    }

    @Test("the request URL carries the scheme's default port and the query")
    func requestURLUsesSchemePort() throws {
        let secure = try GameStreamURL.make(host: "192.0.2.1", secure: true, httpPort: 47989,
                                            httpsPort: 47984, path: "applist",
                                            query: [URLQueryItem(name: "uniqueid", value: "u1")])
        let plain = try GameStreamURL.make(host: "192.0.2.1", secure: false, httpPort: 47989,
                                           httpsPort: 47984, path: "pair",
                                           query: [URLQueryItem(name: "phrase", value: "getservercert")])

        #expect(secure.absoluteString == "https://192.0.2.1:47984/applist?uniqueid=u1")
        #expect(plain.absoluteString == "http://192.0.2.1:47989/pair?phrase=getservercert")
    }
}

#if os(iOS)
/// iOS-only transport behavior that does not need a live host.
/// `createKeychainBacked` needs a keychain the process is entitled to write. A SwiftPM test bundle
/// on the simulator is not, so this skips there; the same code in a signed app has an
/// application-identifier entitlement and does have one.
@Suite("GameStream HTTP transport (URLSession)",
       .enabled(if: KeychainAvailability.isWritable, "requires a writable keychain"))
struct GameStreamURLSessionTransportTests {
    @Test("a secure request before a pin is captured fails closed")
    func secureRequestWithoutPinFailsClosed() async throws {
        let identity = try ClientIdentity.createKeychainBacked()
        let transport = try GameStreamHTTPTransport(host: "192.0.2.1", identity: identity)

        await #expect(throws: PairingError.serverVerificationFailed) {
            _ = try await transport.get(secure: true, path: "applist",
                                        query: [URLQueryItem(name: "uniqueid", value: "u1")])
        }
    }

}

/// Error wording, which needs neither a keychain nor a host.
@Suite("GameStream HTTP transport error wording")
struct GameStreamURLSessionErrorTests {
    @Test("transport errors keep the macOS wording")
    func transportErrorWording() {
        #expect(GameStreamHTTPTransport.message(for: URLError(.timedOut)) == "request timed out")
        #expect(GameStreamHTTPTransport.message(for: URLError(.cannotConnectToHost))
            .hasPrefix("couldn't reach the PC: "))
    }
}
#endif
