import Network

/// Wi-Fi coexistence: interactive service class on stream sockets, never peer-to-peer/AWDL.
public enum NetworkQoS {
    /// Latency-critical RTP video/audio class — Wi-Fi WMM AC_VI.
    public static let streamServiceClass: ServiceClass = .interactiveVideo
    /// Records the ENet control/input class — the socket is configured in C via ENET_SOCKOPT_QOS, not here.
    public static let controlServiceClass: ServiceClass = .interactiveVoice
    /// Stream connections must never use peer-to-peer interfaces, which would ride AWDL.
    public static let includePeerToPeer = false

    /// UDP parameters for RTP video/audio receive sockets.
    public static func streamUDPParameters() -> NWParameters {
        let params = NWParameters.udp
        params.serviceClass = streamServiceClass.nwServiceClass
        params.includePeerToPeer = includePeerToPeer
        return params
    }

    /// TCP parameters for the RTSP control handshake — best-effort, since it is not in the streaming hot loop.
    public static func controlTCPParameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let params = NWParameters(tls: nil, tcp: tcp)
        params.includePeerToPeer = includePeerToPeer
        return params
    }
}

public enum ServiceClass: Sendable, Equatable {
    case bestEffort
    case responsiveData
    case interactiveVideo
    case interactiveVoice

    public var nwServiceClass: NWParameters.ServiceClass {
        switch self {
        case .bestEffort: .bestEffort
        case .responsiveData: .responsiveData
        case .interactiveVideo: .interactiveVideo
        case .interactiveVoice: .interactiveVoice
        }
    }
}
