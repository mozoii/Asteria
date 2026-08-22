import Foundation
import Testing
import GameStreamProtocol
@testable import Pairing

private actor RecordingTransport: GameStreamTransport {
    struct Request: Sendable { let secure: Bool; let path: String; let query: [URLQueryItem]; let body: Data? }
    private(set) var requests: [Request] = []
    private let response: Data
    init(response: Data) { self.response = response }
    func get(secure: Bool, path: String, query: [URLQueryItem]) async throws -> Data {
        requests.append(Request(secure: secure, path: path, query: query, body: nil))
        return response
    }
    func post(secure: Bool, path: String, query: [URLQueryItem], body: Data) async throws -> Data {
        requests.append(Request(secure: secure, path: path, query: query, body: body))
        return response
    }
}

private struct ThrowingTransport: GameStreamTransport {
    struct Unreachable: Error {}
    func get(secure: Bool, path: String, query: [URLQueryItem]) async throws -> Data { throw Unreachable() }
    func post(secure: Bool, path: String, query: [URLQueryItem], body: Data) async throws -> Data { throw Unreachable() }
}

@Suite("HostClient — request convention")
struct HostClientTests {
    private func value(_ q: [URLQueryItem], _ name: String) -> String? { q.first { $0.name == name }?.value }

    @Test func everyRequestCarriesUniqueIdAndRandomUuid() async throws {
        let t = RecordingTransport(response: Data(#"<root status_code="200"><cancel>1</cancel></root>"#.utf8))
        let client = HostClient(transport: t, uniqueId: "abcd1234")

        _ = try await client.cancel()
        _ = try await client.appList()

        let reqs = await t.requests
        #expect(reqs.count == 2)
        #expect(reqs.allSatisfy { value($0.query, "uniqueid") == "abcd1234" })
        let uuids = reqs.compactMap { value($0.query, "uuid") }
        #expect(uuids.count == 2)
        #expect(uuids.allSatisfy { $0.count == 16 && Hex.decode($0) != nil })
        #expect(uuids[0] != uuids[1])
        #expect(reqs.allSatisfy { $0.secure })
    }

    @Test func launchHitsLaunchPathAndParsesSession() async throws {
        let xml = #"<root status_code="200"><sessionUrl0>rtsp://10.0.0.2:48010</sessionUrl0><gamesession>1</gamesession></root>"#
        let t = RecordingTransport(response: Data(xml.utf8))
        let client = HostClient(transport: t, uniqueId: "feed")
        let config = StreamConfiguration(
            width: 1280, height: 720, fps: 60, bitrateKbps: 10_000, packetSize: 1392,
            videoFormat: .hevc, audio: .stereo, hdr: false,
            remoteInputAesKey: Array(0..<16), remoteInputAesKeyId: 1)

        let session = try await client.launch(appId: "42", config: config)
        #expect(session.rtspSessionURL == "rtsp://10.0.0.2:48010")

        let req = try #require(await t.requests.first)
        #expect(req.path == "launch")
        #expect(value(req.query, "appid") == "42")
        #expect(value(req.query, "uniqueid") == "feed")
        #expect(value(req.query, "clientname") == "Asteria")
    }

    @Test func setBitrateHitsBitrateEndpointAndReturnsAppliedKbps() async throws {
        let t = RecordingTransport(response: Data(#"<root status_code="200"><bitrate>18000</bitrate></root>"#.utf8))
        let client = HostClient(transport: t, uniqueId: "feed")

        let applied = try await client.setBitrate(kbps: 20_000)
        #expect(applied == 18_000)

        let req = try #require(await t.requests.first)
        #expect(req.secure)
        #expect(req.path == "bitrate")
        #expect(value(req.query, "bitrate") == "20000")
    }

    @Test func setBitrateReturnsZeroWhenHostRejects() async throws {
        let t = RecordingTransport(response: Data(#"<root status_code="404"><bitrate>0</bitrate></root>"#.utf8))
        let client = HostClient(transport: t, uniqueId: "feed")
        #expect(try await client.setBitrate(kbps: 20_000) == 0)
    }

    @Test func supportsRuntimeBitrateTrueWhenCapabilitiesRouteResponds() async throws {
        // Any success from the capabilities route means the fork exposes runtime /bitrate. The body's
        // `supported` flag is about server-side ABR (which we don't use), so it's deliberately ignored.
        let t = RecordingTransport(response: Data(#"{"supported":false,"version":1,"features":["runtime_bitrate"]}"#.utf8))
        let client = HostClient(transport: t, uniqueId: "feed")
        #expect(await client.supportsRuntimeBitrate())
        #expect(await t.requests.first?.path == "api/abr/capabilities")
    }

    @Test func supportsRuntimeBitrateFalseWhenRouteIsAbsent() async {
        // Mainline Sunshine 404s the route; the transport throws on non-2xx → unsupported, not a crash.
        let client = HostClient(transport: ThrowingTransport(), uniqueId: "feed")
        #expect(await client.supportsRuntimeBitrate() == false)
    }

    @Test func abrCapabilitiesRequireSupportedVersionOne() async throws {
        let data = Data(#"{"supported":true,"version":1,"features":["fallback_threshold"],"llmEnabled":false,"hostMaxBitrate":80000}"#.utf8)
        let transport = RecordingTransport(response: data)
        let client = HostClient(transport: transport, uniqueId: "feed")

        let capabilities = try await client.abrCapabilities()

        #expect(capabilities.supported)
        #expect(capabilities.version == 1)
        #expect(capabilities.isCompatible)
        #expect(capabilities.hostMaxBitrateKbps == 80_000)
        #expect(await transport.requests.first?.path == "api/abr/capabilities")
    }

    @Test func apolloCapabilitiesSelectLocalAdaptiveFallback() async throws {
        let data = Data(
            #"{"supported":false,"version":1,"features":["runtime_bitrate"]}"#.utf8
        )
        let transport = RecordingTransport(response: data)
        let client = HostClient(transport: transport, uniqueId: "feed")

        let capabilities = try await client.abrCapabilities()

        #expect(capabilities.isCompatible == false)
    }

    @Test func configureAbrPostsFoundationJson() async throws {
        let response = Data(#"{"success":true,"enabled":true,"mode":"quality","minBitrate":12000,"maxBitrate":20000,"initialBitrate":20000,"bitrateApplied":true}"#.utf8)
        let transport = RecordingTransport(response: response)
        let client = HostClient(transport: transport, uniqueId: "feed")

        let result = try await client.configureAbr(
            .init(enabled: true, mode: .quality, minBitrateKbps: 12_000,
                  maxBitrateKbps: 20_000))

        #expect(result.success)
        #expect(result.enabled)
        let request = try #require(await transport.requests.first)
        #expect(request.path == "api/abr")
        let body = try #require(request.body)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["enabled"] as? Bool == true)
        #expect(json["mode"] as? String == "quality")
        #expect(json["minBitrate"] as? Int == 12_000)
        #expect(json["maxBitrate"] as? Int == 20_000)
    }

    @Test func abrFeedbackPostsExactMetricContract() async throws {
        let transport = RecordingTransport(
            response: Data(#"{"newBitrate":18000,"bitrateApplied":true,"reason":"fallback: moderate_drop"}"#.utf8))
        let client = HostClient(transport: transport, uniqueId: "feed")

        let result = try await client.sendAbrFeedback(
            .init(packetLossPercent: 2.5, rttMillis: 18, decodeFps: 60,
                  droppedFrames: 2, currentBitrateKbps: 19_500))

        #expect(result.newBitrateKbps == 18_000)
        #expect(result.bitrateApplied)
        let request = try #require(await transport.requests.first)
        #expect(request.path == "api/abr/feedback")
        let body = try #require(request.body)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["packetLoss"] as? Double == 2.5)
        #expect(json["rttMs"] as? Int == 18)
        #expect(json["decodeFps"] as? Int == 60)
        #expect(json["droppedFrames"] as? Int == 2)
        #expect(json["currentBitrate"] as? Int == 19_500)
    }

    @Test func disableAbrPostsOnlyDisabledState() async throws {
        let transport = RecordingTransport(response: Data(#"{"success":true,"enabled":false}"#.utf8))
        let client = HostClient(transport: transport, uniqueId: "feed")

        let result = try await client.disableAbr()

        #expect(result.success)
        let body = try #require(await transport.requests.first?.body)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json.count == 1)
        #expect(json["enabled"] as? Bool == false)
    }

    @Test func setClipboardPostsTextToActionsEndpoint() async throws {
        let t = RecordingTransport(response: Data())
        let client = HostClient(transport: t, uniqueId: "feed")

        try await client.setClipboard("hello world")

        let req = try #require(await t.requests.first)
        #expect(req.secure)
        #expect(req.path == "actions/clipboard")
        #expect(value(req.query, "type") == "text")
        #expect(value(req.query, "uniqueid") == "feed")
        #expect(req.body == Data("hello world".utf8))
    }
}
