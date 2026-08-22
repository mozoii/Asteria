import Network
import Testing
@testable import GameStreamProtocol

@Suite("NetworkQoS")
struct NetworkQoSTests {
    @Test func streamUDPParametersAreInteractiveVideoWithoutPeerToPeer() {
        let params = NetworkQoS.streamUDPParameters()
        #expect(params.serviceClass == .interactiveVideo)
        #expect(params.includePeerToPeer == false)
    }

    @Test func controlTCPParametersDropPeerToPeerAndKeepBestEffortClass() {
        let params = NetworkQoS.controlTCPParameters()
        #expect(params.includePeerToPeer == false)
        #expect(params.serviceClass == .bestEffort)   // RTSP handshake is not in the hot loop
        let tcp = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options
        #expect(tcp?.noDelay == true)
    }

    @Test func serviceClassMapsToNetworkFramework() {
        #expect(ServiceClass.bestEffort.nwServiceClass == .bestEffort)
        #expect(ServiceClass.responsiveData.nwServiceClass == .responsiveData)
        #expect(ServiceClass.interactiveVideo.nwServiceClass == .interactiveVideo)
        #expect(ServiceClass.interactiveVoice.nwServiceClass == .interactiveVoice)
    }
}
