import Foundation

/// Resolves user settings ∩ capabilities into the facts every consumer needs: clamped settings, wire
/// geometry, bitrate, and codec policy. Views render these facts; nothing else re-derives them.
public struct StreamPlan: Sendable, Equatable {
    /// Codec families Asteria negotiates. AV1 hardware decode exists, but the product doesn't
    /// negotiate AV1 yet — the settings picker and the stream negotiator both read this list.
    public static let negotiableCodecs: [CodecPreference] = [.h264, .hevc]

    /// Clamped effective settings, safe to commit or stream.
    public let settings: StreamSettings
    /// Wire dimensions for the chosen resolution against the display.
    public let size: PixelSize
    /// Wire frame rate for the chosen preset against the display refresh.
    public let fps: Int
    /// Starting wire bitrate (manual value, or the recommendation for auto/adaptive).
    public let bitrateKbps: Int
    /// 10-bit stream: preferred by the user or forced by HDR, and the decoder can do it.
    public let preferTenBit: Bool

    public static func resolve(global: StreamSettings, override: StreamSettingsOverride,
                               capabilities: StreamCapabilities) -> StreamPlan {
        resolve(settings: global.applying(override), capabilities: capabilities)
    }

    public static func resolve(settings raw: StreamSettings,
                               capabilities: StreamCapabilities) -> StreamPlan {
        let settings = capabilities.clamp(raw)
        let size = settings.resolution.dimensions(matchingDisplay: capabilities.displaySize)
            ?? PixelSize(width: 1_920, height: 1_080)
        let fps = settings.frameRate.value(matchingDisplay: capabilities.displayRefreshHz) ?? 60
        return StreamPlan(
            settings: settings,
            size: size,
            fps: fps,
            bitrateKbps: settings.bitrate.resolvedKbps(
                recommendedKbps: recommendedKbps(for: settings, capabilities: capabilities)),
            preferTenBit: settings.bitDepth == .preferTenBit && capabilities.supportsTenBit
        )
    }

    /// Balanced first-run defaults: native resolution at 60 fps, 8-bit, newest negotiable codec,
    /// bitrate from the auto curve — a stable starting point the user can raise later.
    public static func firstRunRecommendation(global: StreamSettings,
                                              capabilities: StreamCapabilities) -> StreamSettings {
        var settings = global
        settings.resolution = capabilities.displaySize != nil ? .matchDisplay : .hd1080
        settings.frameRate = .fps(60)
        settings.codec = capabilities.codecs.last ?? .auto
        settings.bitDepth = .eightBit
        settings.bitrate = .manual(kbps: recommendedKbps(for: settings, capabilities: capabilities))
        return settings
    }

    /// Suggested bitrate for Auto/Adaptive labels and first-run defaults: the auto curve anchored
    /// to 125 Mbps at 4K60 SDR, scaled by pixels, frame rate (tapering past 60), 10-bit depth.
    public static func recommendedKbps(for settings: StreamSettings,
                                       capabilities: StreamCapabilities) -> Int {
        let effective = capabilities.clamp(settings)
        let size = effective.resolution.dimensions(matchingDisplay: capabilities.displaySize)
            ?? PixelSize(width: 1_920, height: 1_080)
        let frameRate = effective.frameRate
            .value(matchingDisplay: capabilities.displayRefreshHz) ?? 60
        let pixels = Double(max(1, size.width)) * Double(max(1, size.height))
        let spatialMultiplier = pixels / Double(3_840 * 2_160)
        let depthMultiplier = effective.bitDepth == .preferTenBit ? 305.0 / 250.0 : 1
        let recommendation = 125_000.0 * spatialMultiplier
            * temporalMultiplier(frameRate: frameRate) * depthMultiplier
        return max(500, Int(recommendation.rounded()))
    }

    private static func temporalMultiplier(frameRate: Int) -> Double {
        let frameRate = max(1, frameRate)
        if frameRate <= 60 {
            return Double(frameRate) / 60
        }
        let highFrameRateProgress = min(Double(frameRate - 60) / 180, 1)
        return 1 + highFrameRateProgress
    }
}
