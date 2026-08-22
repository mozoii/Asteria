import Foundation
import GameStreamProtocol

/// PCM sample format: decoder output, render graph input.
public enum AudioSampleFormat: Sendable {
    case float32
    case int16
}
