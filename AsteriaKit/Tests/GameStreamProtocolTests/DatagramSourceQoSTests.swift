import Network
import Testing
@testable import GameStreamProtocol

@Suite("NWDatagramSource QoS")
struct DatagramSourceQoSTests {
    @Test func defaultsToInteractiveVideoWithoutPeerToPeer() {
        let source = NWDatagramSource(host: "192.0.2.1", port: 48000)
        #expect(source.parameters.serviceClass == .interactiveVideo)
        #expect(source.parameters.includePeerToPeer == false)
    }

    @Test func honorsInjectedParameters() {
        let custom = NWParameters.udp
        custom.serviceClass = .bestEffort
        let source = NWDatagramSource(host: "192.0.2.1", port: 48000, parameters: custom)
        #expect(source.parameters.serviceClass == .bestEffort)
    }
}
