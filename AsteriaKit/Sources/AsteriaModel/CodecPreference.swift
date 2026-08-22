/// Preferred video codec; `.auto` lets capability negotiation pick the best supported.
public enum CodecPreference: String, Codable, Sendable, CaseIterable, Hashable {
    case auto, h264, hevc, av1
}

/// Preferred decode bit depth. 10-bit is decoded and rendered to SDR (reduced banding); HDR (a separate toggle) implies 10-bit.
public enum BitDepthPreference: String, Codable, Sendable, CaseIterable, Hashable {
    case eightBit, preferTenBit
}

/// Channel layout requested from the host.
public enum AudioChannels: String, Codable, Sendable, CaseIterable, Hashable {
    case stereo, surround51, surround71
}
