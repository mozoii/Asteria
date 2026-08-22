import Testing
@testable import GameStreamProtocol

@Suite("ENet C interop")
struct ENetTests {
    @Test func initializesAndReportsVersion() {
        #expect(ENet.initializeIfNeeded())
        // version = major<<16 | minor<<8 | patch
        #expect(ENet.linkedVersion > 0)
    }
}
