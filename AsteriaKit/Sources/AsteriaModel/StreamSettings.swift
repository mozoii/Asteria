/// Bit-rate choice: the auto curve, a fixed manual value, or adaptive (auto curve as a ceiling that the
/// runtime controller backs off from under packet loss).
public enum BitrateSetting: Codable, Equatable, Sendable, Hashable {
    case auto
    case manual(kbps: Int)
    case adaptive

    /// The starting/wire bit rate. Adaptive begins at the auto value and only reduces from there at runtime.
    public func resolvedKbps(recommendedKbps: Int) -> Int {
        switch self {
        case .auto, .adaptive: return recommendedKbps
        case let .manual(kbps): return kbps
        }
    }

    public var isAdaptive: Bool { self == .adaptive }

    /// Manual rate from a Mbps figure, clamped to a 500 Kbps floor.
    public static func manual(clampingMbps mbps: Double) -> BitrateSetting {
        .manual(kbps: max(500, Int((mbps * 1000).rounded())))
    }
}

/// How adaptive bitrate trades quality against latency: `preferQuality` holds a higher rate and tolerates
/// more loss before cutting; `preferLatency` drops harder and sooner to protect responsiveness.
public enum AdaptiveMode: String, Codable, Equatable, Sendable, Hashable, CaseIterable {
    case preferQuality
    case preferLatency

    public var displayName: String {
        switch self {
        case .preferQuality: return "Prefer Quality"
        case .preferLatency: return "Prefer Latency"
        }
    }

    /// Compact form for the stats overlay tag.
    public var shortName: String {
        switch self {
        case .preferQuality: return "Quality"
        case .preferLatency: return "Latency"
        }
    }
}

public enum WindowMode: String, Codable, Equatable, Sendable, Hashable, CaseIterable {
    case windowedFullscreen
    case windowed
}

/// Fully-resolved stream knobs (the global default layer).
public struct StreamSettings: Codable, Equatable, Sendable {
    public var resolution: VideoResolution
    public var frameRate: FrameRate
    public var bitrate: BitrateSetting
    /// Aggressiveness of the adaptive-bitrate controller; only consulted when `bitrate` is `.adaptive`.
    public var adaptiveMode: AdaptiveMode
    public var codec: CodecPreference
    public var bitDepth: BitDepthPreference
    /// Request an HDR (BT.2020 PQ) stream. Implies a 10-bit stream and requires an EDR-capable display.
    public var hdr: Bool
    public var enableMetalFX: Bool
    public var audio: AudioChannels
    /// Silence stream audio whenever Asteria isn't the active app.
    public var muteWhenInactive: Bool
    public var windowMode: WindowMode
    /// Remove the local window title bar while using windowed display mode.
    public var hideTitleBarInWindowedMode: Bool
    /// Quit the running app on the host (send /cancel) when the user ends the stream.
    public var closeAppOnDisconnect: Bool
    /// Push the local clipboard to the host while streaming (Apollo hosts only).
    public var syncClipboard: Bool
    /// Keep stream audio playing on the host's own output instead of streaming it locally.
    public var playAudioOnHost: Bool

    public init(resolution: VideoResolution, frameRate: FrameRate, bitrate: BitrateSetting,
                codec: CodecPreference, bitDepth: BitDepthPreference, enableMetalFX: Bool,
                audio: AudioChannels, hdr: Bool = false, muteWhenInactive: Bool = false,
                windowMode: WindowMode = .windowedFullscreen, closeAppOnDisconnect: Bool = false,
                syncClipboard: Bool = false, adaptiveMode: AdaptiveMode = .preferQuality,
                hideTitleBarInWindowedMode: Bool = false, playAudioOnHost: Bool = false) {
        self.resolution = resolution
        self.frameRate = frameRate
        self.bitrate = bitrate
        self.adaptiveMode = adaptiveMode
        self.codec = codec
        self.bitDepth = bitDepth
        self.hdr = hdr
        self.enableMetalFX = enableMetalFX
        self.audio = audio
        self.muteWhenInactive = muteWhenInactive
        self.windowMode = windowMode
        self.hideTitleBarInWindowedMode = hideTitleBarInWindowedMode
        self.closeAppOnDisconnect = closeAppOnDisconnect
        self.syncClipboard = syncClipboard
        self.playAudioOnHost = playAudioOnHost
    }

    // Custom decode so documents written before a field existed load with that field's default.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        resolution = try c.decode(VideoResolution.self, forKey: .resolution)
        frameRate = try c.decode(FrameRate.self, forKey: .frameRate)
        bitrate = try c.decode(BitrateSetting.self, forKey: .bitrate)
        adaptiveMode = try c.decodeIfPresent(AdaptiveMode.self, forKey: .adaptiveMode) ?? .preferQuality
        codec = try c.decode(CodecPreference.self, forKey: .codec)
        bitDepth = try c.decode(BitDepthPreference.self, forKey: .bitDepth)
        hdr = try c.decodeIfPresent(Bool.self, forKey: .hdr) ?? false
        enableMetalFX = try c.decode(Bool.self, forKey: .enableMetalFX)
        audio = try c.decode(AudioChannels.self, forKey: .audio)
        muteWhenInactive = try c.decodeIfPresent(Bool.self, forKey: .muteWhenInactive) ?? false
        windowMode = try c.decodeIfPresent(WindowMode.self, forKey: .windowMode) ?? .windowedFullscreen
        hideTitleBarInWindowedMode = try c.decodeIfPresent(
            Bool.self, forKey: .hideTitleBarInWindowedMode) ?? false
        closeAppOnDisconnect = try c.decodeIfPresent(Bool.self, forKey: .closeAppOnDisconnect) ?? false
        syncClipboard = try c.decodeIfPresent(Bool.self, forKey: .syncClipboard) ?? false
        playAudioOnHost = try c.decodeIfPresent(Bool.self, forKey: .playAudioOnHost) ?? false
    }

    public static let defaults = StreamSettings(
        resolution: .hd1080, frameRate: .fps60, bitrate: .auto, codec: .auto,
        bitDepth: .eightBit, enableMetalFX: false, audio: .stereo, windowMode: .windowedFullscreen)

    /// Apply a sparse per-host override; set fields win, unset fields keep the global value.
    public func applying(_ override: StreamSettingsOverride) -> StreamSettings {
        var result = self
        if let v = override.resolution { result.resolution = v }
        if let v = override.frameRate { result.frameRate = v }
        if let v = override.bitrate { result.bitrate = v }
        if let v = override.adaptiveMode { result.adaptiveMode = v }
        if let v = override.codec { result.codec = v }
        if let v = override.bitDepth { result.bitDepth = v }
        if let v = override.hdr { result.hdr = v }
        if let v = override.enableMetalFX { result.enableMetalFX = v }
        if let v = override.audio { result.audio = v }
        if let v = override.muteWhenInactive { result.muteWhenInactive = v }
        if let v = override.windowMode { result.windowMode = v }
        if let v = override.hideTitleBarInWindowedMode { result.hideTitleBarInWindowedMode = v }
        if let v = override.closeAppOnDisconnect { result.closeAppOnDisconnect = v }
        if let v = override.syncClipboard { result.syncClipboard = v }
        if let v = override.playAudioOnHost { result.playAudioOnHost = v }
        return result
    }
}

/// Sparse per-host override layer; nil means "inherit the global setting".
public struct StreamSettingsOverride: Codable, Equatable, Sendable {
    public var resolution: VideoResolution?
    public var frameRate: FrameRate?
    public var bitrate: BitrateSetting?
    public var adaptiveMode: AdaptiveMode?
    public var codec: CodecPreference?
    public var bitDepth: BitDepthPreference?
    public var hdr: Bool?
    public var enableMetalFX: Bool?
    public var audio: AudioChannels?
    public var muteWhenInactive: Bool?
    public var windowMode: WindowMode?
    public var hideTitleBarInWindowedMode: Bool?
    public var closeAppOnDisconnect: Bool?
    public var syncClipboard: Bool?
    public var playAudioOnHost: Bool?

    public init(resolution: VideoResolution? = nil, frameRate: FrameRate? = nil,
                bitrate: BitrateSetting? = nil, codec: CodecPreference? = nil,
                bitDepth: BitDepthPreference? = nil, hdr: Bool? = nil, enableMetalFX: Bool? = nil,
                audio: AudioChannels? = nil, muteWhenInactive: Bool? = nil,
                windowMode: WindowMode? = nil, closeAppOnDisconnect: Bool? = nil,
                syncClipboard: Bool? = nil, adaptiveMode: AdaptiveMode? = nil,
                hideTitleBarInWindowedMode: Bool? = nil, playAudioOnHost: Bool? = nil) {
        self.resolution = resolution
        self.frameRate = frameRate
        self.bitrate = bitrate
        self.adaptiveMode = adaptiveMode
        self.codec = codec
        self.bitDepth = bitDepth
        self.hdr = hdr
        self.enableMetalFX = enableMetalFX
        self.audio = audio
        self.muteWhenInactive = muteWhenInactive
        self.windowMode = windowMode
        self.hideTitleBarInWindowedMode = hideTitleBarInWindowedMode
        self.closeAppOnDisconnect = closeAppOnDisconnect
        self.syncClipboard = syncClipboard
        self.playAudioOnHost = playAudioOnHost
    }

    public static let empty = StreamSettingsOverride()

    /// Sparse override capturing only the fields where `draft` differs from `global` (the rest inherit).
    public static func diff(_ draft: StreamSettings, from global: StreamSettings) -> StreamSettingsOverride {
        StreamSettingsOverride(
            resolution: draft.resolution == global.resolution ? nil : draft.resolution,
            frameRate: draft.frameRate == global.frameRate ? nil : draft.frameRate,
            bitrate: draft.bitrate == global.bitrate ? nil : draft.bitrate,
            codec: draft.codec == global.codec ? nil : draft.codec,
            bitDepth: draft.bitDepth == global.bitDepth ? nil : draft.bitDepth,
            hdr: draft.hdr == global.hdr ? nil : draft.hdr,
            enableMetalFX: draft.enableMetalFX == global.enableMetalFX ? nil : draft.enableMetalFX,
            audio: draft.audio == global.audio ? nil : draft.audio,
            muteWhenInactive: draft.muteWhenInactive == global.muteWhenInactive ? nil : draft.muteWhenInactive,
            windowMode: draft.windowMode == global.windowMode ? nil : draft.windowMode,
            closeAppOnDisconnect: draft.closeAppOnDisconnect == global.closeAppOnDisconnect ? nil : draft.closeAppOnDisconnect,
            syncClipboard: draft.syncClipboard == global.syncClipboard ? nil : draft.syncClipboard,
            adaptiveMode: draft.adaptiveMode == global.adaptiveMode ? nil : draft.adaptiveMode,
            hideTitleBarInWindowedMode: draft.hideTitleBarInWindowedMode
                == global.hideTitleBarInWindowedMode ? nil : draft.hideTitleBarInWindowedMode,
            playAudioOnHost: draft.playAudioOnHost == global.playAudioOnHost ? nil : draft.playAudioOnHost)
    }
}
