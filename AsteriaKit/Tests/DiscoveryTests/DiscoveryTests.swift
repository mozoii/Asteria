import Foundation
import Testing
@testable import Discovery

@Suite("Discovery (scaffold)")
struct DiscoveryTests {
    @Test func bonjourServiceType() {
        #expect(HostBrowser.serviceType == "_nvstream._tcp")
    }
}
