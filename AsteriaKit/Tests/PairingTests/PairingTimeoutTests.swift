import Foundation
import Testing
@testable import Pairing

struct HangingTransport: GameStreamTransport {
    func get(secure: Bool, path: String, query: [URLQueryItem]) async throws -> Data {
        try await Task.sleep(nanoseconds: 60 * 1_000_000_000)
        return Data()
    }
}

@Suite("Pairing timeout")
struct PairingTimeoutTests {
    @Test func pairingTimesOutWhenPinNeverEntered() async throws {
        let client = PairingClient(transport: HangingTransport(), identity: try ClientIdentity.generate())
        let start = Date()
        await #expect(throws: PairingError.timedOut) {
            _ = try await client.pair(pin: "1234", timeoutSeconds: 0.5)
        }
        // The point is that the 0.5s timeout fired instead of waiting the transport's 60s hang; the margin is
        // wide because wall-clock scheduling jitters badly when the whole suite runs in parallel.
        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed < 30)
    }

    @Test func defaultTimeoutIs300Seconds() {
        #expect(PairingClient.defaultTimeoutSeconds == 300)
    }
}
