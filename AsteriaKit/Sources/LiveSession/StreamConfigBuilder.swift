import GameStreamProtocol
import AsteriaModel

/// Resolves a `StreamPlan` into a wire `StreamSession.Configuration` and decode flags.
public enum StreamConfigBuilder {
    public struct Plan: Sendable {
        public let configuration: StreamSession.Configuration
        public let preferTenBit: Bool
        public let enableMetalFX: Bool
        public let codec: CodecPreference
    }

    public static func plan(appId: String, settings raw: StreamSettings,
                            capabilities caps: StreamCapabilities) -> Plan {
        let plan = StreamPlan.resolve(settings: raw, capabilities: caps)
        let config = StreamSession.Configuration(
            appId: appId, width: plan.size.width, height: plan.size.height, fps: plan.fps,
            bitrateKbps: plan.bitrateKbps, audio: audioConfiguration(plan.settings.audio),
            hdr: plan.settings.hdr, playAudioOnHost: plan.settings.playAudioOnHost)
        return Plan(configuration: config, preferTenBit: plan.preferTenBit,
                    enableMetalFX: plan.settings.enableMetalFX, codec: plan.settings.codec)
    }

    private static func audioConfiguration(_ channels: AudioChannels) -> AudioConfiguration {
        switch channels {
        case .stereo: return .stereo
        case .surround51: return .surround51
        case .surround71: return .surround71
        }
    }
}
