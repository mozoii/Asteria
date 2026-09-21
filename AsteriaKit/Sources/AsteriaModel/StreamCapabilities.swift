import Foundation

/// What a host∩display pairing can actually stream; the settings UI filters choices and clamps unsupported picks.
public struct StreamCapabilities: Sendable, Equatable {
    /// Selectable codecs beyond `.auto` (which is always available).
    public var codecs: [CodecPreference]
    public var supportsTenBit: Bool
    /// The Mac can stream HDR: an EDR-capable display plus a 10-bit hardware decoder.
    public var supportsHDR: Bool
    public var displaySize: PixelSize?
    public var displayRefreshHz: Int?
    /// Resolution presets to offer (already trimmed to the display).
    public var resolutionPresets: [PixelSize]
    /// Frame-rate presets to offer (already trimmed to the display refresh).
    public var frameRatePresets: [Int]
    public var audio: [AudioChannels]

    public init(codecs: [CodecPreference], supportsTenBit: Bool, supportsHDR: Bool = false,
                displaySize: PixelSize? = nil, displayRefreshHz: Int? = nil,
                resolutionPresets: [PixelSize], frameRatePresets: [Int],
                audio: [AudioChannels] = [.stereo, .surround51, .surround71]) {
        self.codecs = codecs
        self.supportsTenBit = supportsTenBit
        self.supportsHDR = supportsHDR
        self.displaySize = displaySize
        self.displayRefreshHz = displayRefreshHz
        self.resolutionPresets = resolutionPresets
        self.frameRatePresets = frameRatePresets
        self.audio = audio
    }

    public static let allResolutionPresets: [PixelSize] = [
        PixelSize(width: 1280, height: 720),
        PixelSize(width: 1920, height: 1080),
        PixelSize(width: 2560, height: 1440),
        PixelSize(width: 3840, height: 2160),
    ]
    public static let allFrameRatePresets = [30, 60, 120, 240]

    /// Every option enabled — previews and the "host/display unknown" fallback.
    public static let unrestricted = StreamCapabilities(
        codecs: [.h264, .hevc, .av1], supportsTenBit: true, supportsHDR: true,
        resolutionPresets: allResolutionPresets, frameRatePresets: allFrameRatePresets)

    /// Build caps. By default the full ladders are offered (the host renders the chosen mode and we
    /// scale to the display); display capabilities drive "Match display" and the bit-rate
    /// recommendation. `limitPresetsToDisplay` trims both ladders to what the panel can show: a
    /// phone's screen is the only place its stream can play, so 4K or 240 fps on a 1320-row 60 Hz
    /// panel is pure encode cost.
    public static func make(codecs: [CodecPreference], supportsTenBit: Bool, supportsHDR: Bool = false,
                            displaySize: PixelSize?, displayRefreshHz: Int?,
                            limitPresetsToDisplay: Bool = false,
                            audio: [AudioChannels] = [.stereo, .surround51, .surround71]) -> StreamCapabilities {
        StreamCapabilities(codecs: codecs, supportsTenBit: supportsTenBit, supportsHDR: supportsHDR,
                           displaySize: displaySize, displayRefreshHz: displayRefreshHz,
                           resolutionPresets: limitPresetsToDisplay
                               ? resolutionPresets(fitting: displaySize) : allResolutionPresets,
                           frameRatePresets: limitPresetsToDisplay
                               ? frameRatePresets(upTo: displayRefreshHz) : allFrameRatePresets,
                           audio: audio)
    }

    /// Ladder rungs that fit the panel in both dimensions. "Match display" covers the panel's own
    /// size, so it is not added here. An unknown display leaves the full ladder.
    static func resolutionPresets(fitting display: PixelSize?) -> [PixelSize] {
        guard let display else { return allResolutionPresets }
        return allResolutionPresets.filter { $0.width <= display.width && $0.height <= display.height }
    }

    /// The ladder cut at the panel's refresh, with the refresh itself added when it isn't a rung
    /// (a 90 Hz panel offers 30, 60 and 90). An unknown refresh leaves the full ladder.
    static func frameRatePresets(upTo refreshHz: Int?) -> [Int] {
        guard let refreshHz, refreshHz > 0 else { return allFrameRatePresets }
        var rates = allFrameRatePresets.filter { $0 <= refreshHz }
        if !rates.contains(refreshHz) { rates.append(refreshHz) }
        return rates
    }

    public func allows(codec: CodecPreference) -> Bool { codec == .auto || codecs.contains(codec) }

    /// HDR rides only on HEVC Main10 — while HDR is on, only HEVC (or `.auto`, which resolves to
    /// HEVC) stays selectable. `clamp` steers by this same predicate.
    public func allowsCodec(_ codec: CodecPreference, whenHDR hdr: Bool) -> Bool {
        allows(codec: codec) && (!hdr || codec == .hevc || codec == .auto)
    }

    /// MetalFX can only add detail when the chosen mode is smaller than the Mac's display in both
    /// dimensions; nil when upscaling can't help (already native, or the display is unknown).
    public func metalFXTarget(for resolution: VideoResolution) -> PixelSize? {
        guard let display = displaySize,
              let frame = resolution.dimensions(matchingDisplay: display),
              display.width > frame.width, display.height > frame.height else { return nil }
        return display
    }

    /// Codec choices for the picker: `.auto`, then every real codec in a stable order, each enabled only when this
    /// machine can decode it — undecodable codecs stay visible but greyed out rather than vanishing.
    public var codecChoices: [(codec: CodecPreference, enabled: Bool)] {
        [(.auto, true)] + CodecPreference.allCases
            .filter { $0 != .auto }
            .map { (codec: $0, enabled: codecs.contains($0)) }
    }

    /// Downgrade settings the host/display can't honor: unsupported codec → `.auto`, undecodable 10-bit → 8-bit,
    /// impossible HDR → off. HDR that survives forces 10-bit and steers a non-`.auto` codec to HEVC (see `allows(codec:)`).
    public func clamp(_ settings: StreamSettings) -> StreamSettings {
        var result = settings
        if !allows(codec: result.codec) { result.codec = .auto }
        if result.hdr && !supportsHDR { result.hdr = false }
        if result.bitDepth == .preferTenBit && !supportsTenBit { result.bitDepth = .eightBit }
        // Pickability predicate from `allowsCodec`: only non-auto, non-HEVC fails under HDR.
        if result.hdr, !allowsCodec(result.codec, whenHDR: true) { result.codec = .hevc }
        if result.hdr { result.bitDepth = .preferTenBit }
        return result
    }
}
