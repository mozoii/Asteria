import Foundation

public protocol RTSPTransport: Sendable {
    func send(_ request: RTSPRequest) async throws -> RTSPResponse
}

public enum RTSPError: Error, Equatable {
    case status(method: String, code: Int)
    case transport(String)
}

/// Successful RTSP handshake result: session ID, server SDP, and server ports from SETUP.
public struct RTSPSessionResult: Sendable, Equatable {
    public let sessionId: String?
    public let serverSDP: String
    public let audioPort: Int?
    public let videoPort: Int?
    public let controlPort: Int?
    /// ENet token from control SETUP's X-SS-Connect-Data header.
    public let controlConnectData: UInt32
    /// NAT-punch ping payload from video SETUP's X-SS-Ping-Payload header (Sunshine); nil = legacy "PING".
    public let videoPingPayload: [UInt8]?
    /// NAT-punch ping payload from audio SETUP's X-SS-Ping-Payload header, if present.
    public let audioPingPayload: [UInt8]?
}

/// GameStream RTSP handshake: OPTIONS → DESCRIBE → SETUP → ANNOUNCE → PLAY.
public actor RTSPHandshake {
    private let transport: RTSPTransport
    private let host: String
    private let baseURI: String
    private var cseq = 0
    private var sessionId: String?

    /// Host's DESCRIBE SDP (readable even if later stage fails).
    public private(set) var lastServerSDP: String?

    public init(transport: RTSPTransport, host: String, port: UInt16) {
        self.transport = transport
        self.host = host
        self.baseURI = "rtsp://\(host):\(port)"
    }

    /// GameStream hosts require the client protocol version on every RTSP request.
    private static let clientVersion = "14"
    /// Sunshine/GFE expect this fixed conditional-GET header on DESCRIBE/SETUP.
    private static let epoch = "Thu, 01 Jan 1970 00:00:00 GMT"
    /// Stream-id targets for Sunshine ≥ 7.1.431 (control uses /13/0).
    private static let controlStreamId = "streamid=control/13/0"

    /// Extract NNNNN from a `server_port=NNNNN` RTSP Transport header.
    static func serverPort(from transport: String) -> Int? {
        guard let range = transport.range(of: "server_port=") else { return nil }
        let digits = transport[range.upperBound...].prefix { $0.isNumber }
        return Int(digits)
    }

    private func send(_ method: String, target: String,
                      headers: [(String, String)] = [], body: Data? = nil) async throws -> RTSPResponse {
        cseq += 1
        var h = [("X-GS-ClientVersion", Self.clientVersion), ("Host", host)] + headers
        if let sessionId { h.append(("Session", sessionId)) }
        let response = try await transport.send(
            RTSPRequest(method: method, uri: target, cseq: cseq, headers: h, body: body)
        )
        guard (200...299).contains(response.statusCode) else {
            throw RTSPError.status(method: method, code: response.statusCode)
        }
        if sessionId == nil, let s = response.headerValue("session") {
            sessionId = s.components(separatedBy: ";").first
        }
        return response
    }

    public func perform(config: StreamConfiguration) async throws -> RTSPSessionResult {
        _ = try await send("OPTIONS", target: baseURI)

        let describe = try await send("DESCRIBE", target: baseURI,
                                      headers: [("Accept", "application/sdp"), ("If-Modified-Since", Self.epoch)])
        let serverSDP = String(decoding: describe.body, as: UTF8.self)
        lastServerSDP = serverSDP
        let parsed = SessionDescription(parsing: serverSDP)

        let setupHeaders = [("Transport", "unicast;X-GS-ClientPort=50000-50001"), ("If-Modified-Since", Self.epoch)]
        var ports: [String: Int] = [:]
        var connectData: UInt32 = 0
        var videoPingPayload: [UInt8]?
        var audioPingPayload: [UInt8]?
        // The audio SETUP always happens, even when audio plays on the host: the SETUP response
        // carries the audio server port and the NAT-punch ping payload, and the client must keep
        // pinging the audio socket or Sunshine aborts the session on its initial-ping gate.
        let streams = [("audio", "streamid=audio/0/0"), ("video", "streamid=video/0/0"), ("control", Self.controlStreamId)]
        for (name, target) in streams {
            let resp = try await send("SETUP", target: target, headers: setupHeaders)
            if let transport = resp.headerValue("transport"), let port = Self.serverPort(from: transport) {
                ports[name] = port
            }
            if name == "control", let raw = resp.headerValue("x-ss-connect-data"), let v = UInt32(raw) {
                connectData = v
            }
            if let p = resp.headerValue("x-ss-ping-payload"), p.utf8.count == 16 {
                if name == "video" { videoPingPayload = Array(p.utf8) }
                else if name == "audio" { audioPingPayload = Array(p.utf8) }
            }
        }
        _ = parsed

        let announce = Data(AnnounceSDPBuilder.announce(for: config, host: host,
                                                        videoServerPort: ports["video"] ?? 47998).utf8)
        _ = try await send("ANNOUNCE", target: Self.controlStreamId,
                           headers: [("Content-Type", "application/sdp")], body: announce)

        _ = try await send("PLAY", target: "/")

        return RTSPSessionResult(sessionId: sessionId, serverSDP: serverSDP,
                                 audioPort: ports["audio"], videoPort: ports["video"], controlPort: ports["control"],
                                 controlConnectData: connectData, videoPingPayload: videoPingPayload,
                                 audioPingPayload: audioPingPayload)
    }
}
