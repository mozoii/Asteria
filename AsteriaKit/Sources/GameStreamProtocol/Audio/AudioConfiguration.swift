import Foundation

public struct AudioConfiguration: Equatable, Sendable, Hashable {
    public let channelCount: Int
    public let channelMask: Int

    public init(channelCount: Int, channelMask: Int) {
        self.channelCount = channelCount
        self.channelMask = channelMask
    }

    public static let stereo      = AudioConfiguration(channelCount: 2, channelMask: 0x3)
    public static let surround51  = AudioConfiguration(channelCount: 6, channelMask: 0x3F)
    public static let surround71  = AudioConfiguration(channelCount: 8, channelMask: 0x63F)
}
