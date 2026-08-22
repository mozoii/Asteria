import Foundation
import Testing
@testable import Pairing

@Suite("GameStream HTTP transport")
struct GameStreamHTTPTransportTests {
    @Test("server certificate pin requires an exact DER match")
    func serverCertificatePinMatch() {
        let pinned = Data([0x30, 0x82, 0x01])

        #expect(GameStreamHTTPTransport.serverCertificateMatchesPin(
            presented: pinned,
            pinned: pinned
        ))
        #expect(!GameStreamHTTPTransport.serverCertificateMatchesPin(
            presented: Data([0x30, 0x82, 0x02]),
            pinned: pinned
        ))
        #expect(!GameStreamHTTPTransport.serverCertificateMatchesPin(
            presented: nil,
            pinned: pinned
        ))
        #expect(!GameStreamHTTPTransport.serverCertificateMatchesPin(
            presented: pinned,
            pinned: nil
        ))
    }
}
