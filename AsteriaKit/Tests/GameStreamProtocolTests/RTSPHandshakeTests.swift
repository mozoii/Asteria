import Foundation
import Testing
@testable import GameStreamProtocol

actor SimulatedRtspServer: RTSPTransport {
    struct Seen: Sendable {
        let method: String; let cseq: Int; let session: String?; let uri: String
        let headers: [(String, String)]
        func header(_ name: String) -> String? { headers.first { $0.0.lowercased() == name.lowercased() }?.1 }
    }
    private(set) var log: [Seen] = []
    let sessionId = "DEADBEEFCAFE"

    func record() -> [Seen] { log }

    func send(_ request: RTSPRequest) async throws -> RTSPResponse {
        let session = request.headers.first { $0.0.lowercased() == "session" }?.1
        log.append(Seen(method: request.method, cseq: request.cseq, session: session,
                        uri: request.uri, headers: request.headers))

        var raw = "RTSP/1.0 200 OK\r\nCSeq: \(request.cseq)\r\n"
        var body = ""
        switch request.method {
        case "SETUP":
            raw += "Session: \(sessionId);timeout=60\r\n"
            let port = request.uri.contains("audio") ? 48000 : request.uri.contains("video") ? 47998 : 47999
            raw += "Transport: server_port=\(port)\r\n"
        case "DESCRIBE":
            body = [
                "v=0", "o=- 0 0 IN IP4 10.0.0.5", "s=Sunshine",
                "t=0 0", "m=video 47998 RTP/AVP 97", "m=audio 48000 RTP/AVP 98",
            ].joined(separator: "\r\n") + "\r\n"
        default:
            break
        }
        if !body.isEmpty { raw += "Content-Length: \(body.utf8.count)\r\n" }
        raw += "\r\n" + body
        return RTSPResponse(parsing: Data(raw.utf8))!
    }
}

@Suite("RTSP handshake sequencing")
struct RTSPHandshakeTests {

    private func config() -> StreamConfiguration {
        StreamConfiguration(
            width: 1920, height: 1080, fps: 60, bitrateKbps: 20_000, packetSize: 1392,
            videoFormat: .hevc, audio: .stereo, hdr: false,
            remoteInputAesKey: Array(repeating: 0, count: 16), remoteInputAesKeyId: 0
        )
    }

    @Test func runsFullHandshakeInOrder() async throws {
        let server = SimulatedRtspServer()
        let handshake = RTSPHandshake(transport: server, host: "10.0.0.5", port: 48010)
        let result = try await handshake.perform(config: config())

        let seen = await server.record()
        #expect(seen.map(\.method) == ["OPTIONS", "DESCRIBE", "SETUP", "SETUP", "SETUP", "ANNOUNCE", "PLAY"])
        #expect(seen.map(\.cseq) == [1, 2, 3, 4, 5, 6, 7])
        #expect(result.sessionId == "DEADBEEFCAFE")
        #expect(result.audioPort == 48000)
        #expect(result.videoPort == 47998)
        #expect(result.controlPort == 47999)
    }

    @Test("Host-side audio still needs the audio SETUP: the client must ping the audio socket")
    func keepsAudioSetupWhenPlayAudioOnHost() async throws {
        let server = SimulatedRtspServer()
        let handshake = RTSPHandshake(transport: server, host: "10.0.0.5", port: 48010)
        var hostAudio = config()
        hostAudio.playAudioOnHost = true
        let result = try await handshake.perform(config: hostAudio)

        let seen = await server.record()
        #expect(seen.map(\.method) == ["OPTIONS", "DESCRIBE", "SETUP", "SETUP", "SETUP", "ANNOUNCE", "PLAY"])
        #expect(seen.map(\.cseq) == [1, 2, 3, 4, 5, 6, 7])
        let setups = seen.filter { $0.method == "SETUP" }.map(\.uri)
        #expect(setups == ["streamid=audio/0/0", "streamid=video/0/0", "streamid=control/13/0"])
        #expect(result.audioPort == 48000)
        #expect(result.videoPort == 47998)
        #expect(result.controlPort == 47999)
    }

    @Test func everyRequestCarriesVersionAndHost() async throws {
        let server = SimulatedRtspServer()
        let handshake = RTSPHandshake(transport: server, host: "10.0.0.5", port: 48010)
        _ = try await handshake.perform(config: config())
        for req in await server.record() {
            #expect(req.header("X-GS-ClientVersion") == "14")
            #expect(req.header("Host") == "10.0.0.5")
        }
    }

    @Test func describeAndSetupSendConditionalGetHeader() async throws {
        let server = SimulatedRtspServer()
        let handshake = RTSPHandshake(transport: server, host: "10.0.0.5", port: 48010)
        _ = try await handshake.perform(config: config())
        let seen = await server.record()
        let epoch = "Thu, 01 Jan 1970 00:00:00 GMT"
        #expect(seen.first { $0.method == "DESCRIBE" }?.header("If-Modified-Since") == epoch)
        for setup in seen.filter({ $0.method == "SETUP" }) {
            #expect(setup.header("If-Modified-Since") == epoch)
            #expect(setup.header("Transport") == "unicast;X-GS-ClientPort=50000-50001")
        }
    }

    @Test func usesCorrectTargetsForSunshine() async throws {
        let server = SimulatedRtspServer()
        let handshake = RTSPHandshake(transport: server, host: "10.0.0.5", port: 48010)
        _ = try await handshake.perform(config: config())
        let seen = await server.record()
        #expect(seen[0].uri == "rtsp://10.0.0.5:48010")
        #expect(seen[1].uri == "rtsp://10.0.0.5:48010")
        let setups = seen.filter { $0.method == "SETUP" }.map(\.uri)
        #expect(setups == ["streamid=audio/0/0", "streamid=video/0/0", "streamid=control/13/0"])
        #expect(seen.first { $0.method == "ANNOUNCE" }?.uri == "streamid=control/13/0")
        #expect(seen.first { $0.method == "PLAY" }?.uri == "/")
    }

    @Test func sessionIdPropagatesAfterFirstSetup() async throws {
        let server = SimulatedRtspServer()
        let handshake = RTSPHandshake(transport: server, host: "10.0.0.5", port: 48010)
        _ = try await handshake.perform(config: config())
        let seen = await server.record()

        #expect(seen[0].session == nil)
        #expect(seen[2].session == nil)
        #expect(seen[5].session == "DEADBEEFCAFE")
        #expect(seen[6].session == "DEADBEEFCAFE")
    }

    @Test func nonSuccessStatusThrows() async throws {
        struct Rejecting: RTSPTransport {
            func send(_ request: RTSPRequest) async throws -> RTSPResponse {
                RTSPResponse(parsing: Data("RTSP/1.0 500 Internal Server Error\r\nCSeq: \(request.cseq)\r\n\r\n".utf8))!
            }
        }
        let handshake = RTSPHandshake(transport: Rejecting(), host: "h", port: 48010)
        await #expect(throws: RTSPError.self) {
            _ = try await handshake.perform(config: config())
        }
    }
}
