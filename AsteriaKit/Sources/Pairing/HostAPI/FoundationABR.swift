import Foundation
import GameStreamProtocol

public enum FoundationABRMode: String, Codable, Sendable {
    case quality
    case lowLatency
}

public struct FoundationABRCapabilities: Decodable, Equatable, Sendable {
    public let supported: Bool
    public let version: Int
    public let features: [String]
    public let llmEnabled: Bool
    public let hostMaxBitrateKbps: Int

    public var isCompatible: Bool { supported && version == 1 }

    private enum CodingKeys: String, CodingKey {
        case supported, version, features, llmEnabled
        case hostMaxBitrateKbps = "hostMaxBitrate"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        supported = try container.decode(Bool.self, forKey: .supported)
        version = try container.decode(Int.self, forKey: .version)
        features = try container.decode([String].self, forKey: .features)
        if supported {
            llmEnabled = try container.decode(Bool.self, forKey: .llmEnabled)
            hostMaxBitrateKbps = try container.decode(Int.self, forKey: .hostMaxBitrateKbps)
        } else {
            llmEnabled = try container.decodeIfPresent(Bool.self, forKey: .llmEnabled) ?? false
            hostMaxBitrateKbps = try container.decodeIfPresent(
                Int.self,
                forKey: .hostMaxBitrateKbps
            ) ?? 0
        }
    }
}

public struct FoundationABRConfiguration: Encodable, Equatable, Sendable {
    public let enabled: Bool
    public let mode: FoundationABRMode
    public let minBitrateKbps: Int
    public let maxBitrateKbps: Int

    public init(enabled: Bool, mode: FoundationABRMode, minBitrateKbps: Int,
                maxBitrateKbps: Int) {
        self.enabled = enabled
        self.mode = mode
        self.minBitrateKbps = minBitrateKbps
        self.maxBitrateKbps = maxBitrateKbps
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, mode
        case minBitrateKbps = "minBitrate"
        case maxBitrateKbps = "maxBitrate"
    }
}

public struct FoundationABRConfigurationResponse: Decodable, Equatable, Sendable {
    public let success: Bool
    public let enabled: Bool
    public let mode: String?
    public let minBitrateKbps: Int?
    public let maxBitrateKbps: Int?
    public let initialBitrateKbps: Int?
    public let bitrateApplied: Bool?
    public let error: String?

    private enum CodingKeys: String, CodingKey {
        case success, enabled, mode, bitrateApplied, error
        case minBitrateKbps = "minBitrate"
        case maxBitrateKbps = "maxBitrate"
        case initialBitrateKbps = "initialBitrate"
    }
}

public struct FoundationABRFeedback: Encodable, Equatable, Sendable {
    public let packetLossPercent: Double
    public let rttMillis: Int
    public let decodeFps: Int
    public let droppedFrames: Int
    public let currentBitrateKbps: Int

    public init(packetLossPercent: Double, rttMillis: Int, decodeFps: Int,
                droppedFrames: Int, currentBitrateKbps: Int) {
        self.packetLossPercent = packetLossPercent
        self.rttMillis = rttMillis
        self.decodeFps = decodeFps
        self.droppedFrames = droppedFrames
        self.currentBitrateKbps = currentBitrateKbps
    }

    private enum CodingKeys: String, CodingKey {
        case packetLossPercent = "packetLoss"
        case rttMillis = "rttMs"
        case decodeFps, droppedFrames
        case currentBitrateKbps = "currentBitrate"
    }
}

public struct FoundationABRFeedbackResponse: Decodable, Equatable, Sendable {
    public let newBitrateKbps: Int?
    public let bitrateApplied: Bool
    public let reason: String

    private enum CodingKeys: String, CodingKey {
        case newBitrateKbps = "newBitrate"
        case bitrateApplied, reason
    }
}

public extension HostClient {
    func abrCapabilities() async throws -> FoundationABRCapabilities {
        let data = try await transport.get(
            secure: true, path: "api/abr/capabilities",
            query: HostQuery.base(uniqueId: uniqueId))
        return try JSONDecoder().decode(FoundationABRCapabilities.self, from: data)
    }

    func configureAbr(
        _ configuration: FoundationABRConfiguration
    ) async throws -> FoundationABRConfigurationResponse {
        try await postAbr(path: "api/abr", value: configuration)
    }

    func sendAbrFeedback(
        _ feedback: FoundationABRFeedback
    ) async throws -> FoundationABRFeedbackResponse {
        try await postAbr(path: "api/abr/feedback", value: feedback)
    }

    func disableAbr() async throws -> FoundationABRConfigurationResponse {
        let body = try JSONSerialization.data(withJSONObject: ["enabled": false])
        let data = try await transport.post(
            secure: true, path: "api/abr", query: HostQuery.base(uniqueId: uniqueId),
            body: body)
        return try JSONDecoder().decode(FoundationABRConfigurationResponse.self, from: data)
    }

    private func postAbr<Value: Encodable, Response: Decodable>(
        path: String, value: Value
    ) async throws -> Response {
        let body = try JSONEncoder().encode(value)
        let data = try await transport.post(
            secure: true, path: path, query: HostQuery.base(uniqueId: uniqueId), body: body)
        return try JSONDecoder().decode(Response.self, from: data)
    }
}
