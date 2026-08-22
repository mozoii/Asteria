import Foundation
import Testing
import GameStreamProtocol
@testable import Pairing

@Suite("Launch / resume / cancel control")
struct LaunchControlTests {
    private func config() -> StreamConfiguration {
        StreamConfiguration(
            width: 1920, height: 1080, fps: 60,
            bitrateKbps: 20_000, packetSize: 1392,
            videoFormat: .hevc, audio: .stereo, hdr: false,
            remoteInputAesKey: Array(0..<16), remoteInputAesKeyId: 0x01020304
        )
    }

    private func valueOf(_ items: [URLQueryItem], _ name: String) -> String? {
        items.first { $0.name == name }?.value
    }

    @Test func launchQueryCarriesStreamConfig() {
        let q = HostClient.launchQuery(
            uniqueId: "abcd1234", appId: "881448767", config: config(),
            sops: true, localAudioPlayMode: false
        )
        #expect(valueOf(q, "uniqueid") == "abcd1234")
        #expect(valueOf(q, "appid") == "881448767")
        #expect(valueOf(q, "mode") == "1920x1080x60")
        #expect(valueOf(q, "rikey") == "000102030405060708090a0b0c0d0e0f")
        #expect(valueOf(q, "rikeyid") == "16909060")
        #expect(valueOf(q, "sops") == "1")
        #expect(valueOf(q, "additionalStates") == "1")
        #expect(valueOf(q, "localAudioPlayMode") == "0")
        #expect(valueOf(q, "surroundAudioInfo") == "\((0x3 << 16) | 2)")
        #expect(valueOf(q, "hdrMode") == "0")
        #expect(valueOf(q, "uuid") != nil)
    }

    @Test func sopsAndHdrFlagsReflectArguments() {
        var c = config(); c.hdr = true
        let q = HostClient.launchQuery(uniqueId: "x", appId: "1", config: c, sops: false, localAudioPlayMode: true)
        #expect(valueOf(q, "sops") == "0")
        #expect(valueOf(q, "hdrMode") == "1")
        #expect(valueOf(q, "localAudioPlayMode") == "1")
    }

    @Test func parsesLaunchSession() throws {
        let xml = Data(#"<root status_code="200"><sessionUrl0>rtsp://10.0.0.2:48010</sessionUrl0><gamesession>1</gamesession></root>"#.utf8)
        let session = try LaunchSession(parsingLaunch: xml)
        #expect(session.rtspSessionURL == "rtsp://10.0.0.2:48010")
        #expect(session.gameSession == 1)
    }

    @Test func parsesResumeSession() throws {
        let xml = Data(#"<root status_code="200"><sessionUrl0>rtsp://10.0.0.2:48010</sessionUrl0><resume>1</resume></root>"#.utf8)
        let session = try LaunchSession(parsingResume: xml)
        #expect(session.rtspSessionURL == "rtsp://10.0.0.2:48010")
        #expect(session.gameSession == 1)
    }

    @Test func launchFailureThrows() {
        let xml = Data(#"<root status_code="200"><gamesession>0</gamesession></root>"#.utf8)
        #expect(throws: PairingError.self) { _ = try LaunchSession(parsingLaunch: xml) }
    }

    @Test func launchSurfacesHostStatusMessage() {
        let xml = Data(##"<root status_code="403" status_message="Permission denied: lacks the &quot;Launch applications&quot; permission."><resume>0</resume></root>"##.utf8)
        do {
            _ = try LaunchSession(parsingLaunch: xml)
            Issue.record("expected throw")
        } catch let PairingError.launchRejected(code, message) {
            #expect(code == 403)
            #expect(message.contains("Launch applications"))
            #expect(!message.contains("&quot;"))
        } catch {
            Issue.record("wrong error: \(error)")
        }
    }

    @Test func parsesCancel() {
        #expect(HostClient.parseCancel(Data(#"<root status_code="200"><cancel>1</cancel></root>"#.utf8)) == true)
        #expect(HostClient.parseCancel(Data(#"<root status_code="200"><cancel>0</cancel></root>"#.utf8)) == false)
    }
}
