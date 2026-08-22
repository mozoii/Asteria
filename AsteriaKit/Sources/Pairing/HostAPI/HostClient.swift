import Foundation
import GameStreamProtocol
import AsteriaCore

/// Authenticated host control (pairs transport with `uniqueId`).
public struct HostClient: Sendable {
    let transport: GameStreamTransport
    public let uniqueId: String

    public init(transport: GameStreamTransport, uniqueId: String) {
        self.transport = transport
        self.uniqueId = uniqueId
    }

    /// GET /applist — host's advertised apps.
    public func appList() async throws -> [GameApp] {
        let data = try await transport.get(secure: true, path: "applist", query: HostQuery.base(uniqueId: uniqueId))
        return AppListParser.parse(data)
    }

    /// GET /serverinfo over the paired HTTPS channel — running-app and pair state are only revealed when authenticated.
    public func serverInfo() async throws -> Data {
        try await transport.get(secure: true, path: "serverinfo", query: HostQuery.base(uniqueId: uniqueId))
    }

    /// GET /appasset — box-art image bytes for an app (AssetType 2 = box art); empty/invalid when the host has none.
    public func appAsset(appId: String) async throws -> Data {
        try await transport.get(secure: true, path: "appasset", query: HostQuery.base(uniqueId: uniqueId, [
            URLQueryItem(name: "appid", value: appId),
            URLQueryItem(name: "AssetType", value: "2"),
            URLQueryItem(name: "AssetIdx", value: "0"),
        ]))
    }

    /// GET /launch — start streaming session (returns RTSP URL).
    public func launch(
        appId: String, config: StreamConfiguration,
        sops: Bool = true, localAudioPlayMode: Bool = false
    ) async throws -> LaunchSession {
        let data = try await transport.get(
            secure: true, path: "launch",
            query: Self.launchQuery(uniqueId: uniqueId, appId: appId, config: config,
                                    sops: sops, localAudioPlayMode: localAudioPlayMode)
        )
        return try LaunchSession(parsingLaunch: data)
    }

    /// GET /resume — reconnect to running session. Sends the full launch param set: Sunshine rebuilds the
    /// session from these args and won't re-arm the video encoder without `mode` (else video never streams).
    public func resume(
        appId: String, config: StreamConfiguration,
        sops: Bool = true, localAudioPlayMode: Bool = false
    ) async throws -> LaunchSession {
        let data = try await transport.get(
            secure: true, path: "resume",
            query: Self.launchQuery(uniqueId: uniqueId, appId: appId, config: config,
                                    sops: sops, localAudioPlayMode: localAudioPlayMode)
        )
        return try LaunchSession(parsingResume: data)
    }

    /// GET /cancel — quit running session.
    public func cancel() async throws -> Bool {
        let data = try await transport.get(secure: true, path: "cancel", query: HostQuery.base(uniqueId: uniqueId))
        return Self.parseCancel(data)
    }

    /// POST /actions/clipboard — push the client's clipboard text onto the host (Apollo-only). The host
    /// authorizes by client cert and requires this client to have an active stream; the body is the raw UTF-8 text.
    public func setClipboard(_ text: String) async throws {
        _ = try await transport.post(
            secure: true, path: "actions/clipboard",
            query: HostQuery.base(uniqueId: uniqueId, [URLQueryItem(name: "type", value: "text")]),
            body: Data(text.utf8))
    }


    /// GET /bitrate: runtime bitrate change (Vibepollo only; Sunshine/Apollo lack the endpoint). Returns the
    /// Kbps the host applied (it may clamp to its own ceiling), or 0 when it rejected the request.
    @discardableResult
    public func setBitrate(kbps: Int) async throws -> Int {
        let data = try await transport.get(
            secure: true, path: "bitrate",
            query: HostQuery.base(uniqueId: uniqueId, [URLQueryItem(name: "bitrate", value: String(kbps))]))
        return HostClient.parseAppliedBitrate(data)
    }

    /// GET /api/abr/capabilities: probes Vibepollo-only runtime `/bitrate` support (mainline Sunshine 404s it).
    /// Ignores the body's `supported` flag (server-side ABR, not client-driven); a transport failure reads unsupported.
    public func supportsRuntimeBitrate() async -> Bool {
        (try? await transport.get(
            secure: true, path: "api/abr/capabilities", query: HostQuery.base(uniqueId: uniqueId))) != nil
    }

    static func parseAppliedBitrate(_ data: Data) -> Int {
        (try? FlatXML(parsing: data))?.int("bitrate") ?? 0
    }

    public static func launchQuery(
        uniqueId: String, appId: String, config: StreamConfiguration,
        sops: Bool, localAudioPlayMode: Bool
    ) -> [URLQueryItem] {
        HostQuery.base(uniqueId: uniqueId, [
            URLQueryItem(name: "clientname", value: HostQuery.clientName),
            URLQueryItem(name: "appid", value: appId),
            URLQueryItem(name: "mode", value: config.modeString),
            URLQueryItem(name: "additionalStates", value: "1"),
            URLQueryItem(name: "sops", value: sops ? "1" : "0"),
            URLQueryItem(name: "rikey", value: config.rikeyHex),
            URLQueryItem(name: "rikeyid", value: config.rikeyIdString),
            URLQueryItem(name: "localAudioPlayMode", value: localAudioPlayMode ? "1" : "0"),
            URLQueryItem(name: "surroundAudioInfo", value: String(config.surroundAudioInfo)),
            URLQueryItem(name: "remoteControllersBitmap", value: "0"),
            URLQueryItem(name: "gcmap", value: "0"),
            URLQueryItem(name: "gcpersist", value: "0"),
            URLQueryItem(name: "hdrMode", value: config.hdr ? "1" : "0"),
        ])
    }

    public static func parseCancel(_ data: Data) -> Bool {
        (try? FlatXML(parsing: data))?.int("cancel") == 1
    }
}
