import CoreAudioTypes

/// Reorders interleaved PCM from client to CoreAudio canonical channel order; only 7.1 actually reorders.
public struct ChannelRemap: Sendable, Equatable {
    public let channelCount: Int
    /// `sourceForDestination[d]` = the Opus-order channel feeding canonical channel `d`.
    public let sourceForDestination: [Int]
    public let layoutTag: AudioChannelLayoutTag

    public init?(channelCount: Int) {
        switch channelCount {
        case 2:
            sourceForDestination = [0, 1]
            layoutTag = kAudioChannelLayoutTag_Stereo
        case 6:
            sourceForDestination = [0, 1, 2, 3, 4, 5]
            layoutTag = kAudioChannelLayoutTag_MPEG_5_1_A
        case 8:
            // Opus FL FR C LFE RL RR SL SR -> canonical L R C LFE Ls Rs Rls Rrs (sides before rears).
            sourceForDestination = [0, 1, 2, 3, 6, 7, 4, 5]
            layoutTag = kAudioChannelLayoutTag_MPEG_7_1_C
        default:
            return nil
        }
        self.channelCount = channelCount
    }

    public var isIdentity: Bool { sourceForDestination == Array(0..<channelCount) }

    /// Reorder an interleaved buffer (length a multiple of `channelCount`) into canonical order.
    public func remap(_ interleaved: [Float]) -> [Float] {
        guard !isIdentity else { return interleaved }
        var out = [Float](repeating: 0, count: interleaved.count)
        let frames = interleaved.count / channelCount
        for frame in 0..<frames {
            let base = frame * channelCount
            for destination in 0..<channelCount {
                out[base + destination] = interleaved[base + sourceForDestination[destination]]
            }
        }
        return out
    }
}
