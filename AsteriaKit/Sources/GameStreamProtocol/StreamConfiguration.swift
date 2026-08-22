import Foundation
import Security

/// Negotiated stream parameters. remoteInputAesKey/Id seed input-stream AES encryption.
public struct StreamConfiguration: Sendable, Equatable {
    public var width: Int
    public var height: Int
    public var fps: Int
    public var bitrateKbps: Int
    public var packetSize: Int
    public var videoFormat: VideoFormat
    public var audio: AudioConfiguration
    public var hdr: Bool
    public var playAudioOnHost: Bool
    public var remoteInputAesKey: [UInt8]
    public var remoteInputAesKeyId: Int32

    public init(
        width: Int, height: Int, fps: Int,
        bitrateKbps: Int, packetSize: Int,
        videoFormat: VideoFormat, audio: AudioConfiguration, hdr: Bool,
        playAudioOnHost: Bool = false,
        remoteInputAesKey: [UInt8], remoteInputAesKeyId: Int32
    ) {
        self.width = width
        self.height = height
        self.fps = fps
        self.bitrateKbps = bitrateKbps
        self.packetSize = packetSize
        self.videoFormat = videoFormat
        self.audio = audio
        self.hdr = hdr
        self.playAudioOnHost = playAudioOnHost
        self.remoteInputAesKey = remoteInputAesKey
        self.remoteInputAesKeyId = remoteInputAesKeyId
    }

    public var modeString: String { "\(width)x\(height)x\(fps)" }

    public var rikeyHex: String { remoteInputAesKey.map { String(format: "%02x", $0) }.joined() }

    public var rikeyIdString: String { String(remoteInputAesKeyId) }

    public var surroundAudioInfo: Int { (audio.channelMask << 16) | audio.channelCount }

    public static func randomRemoteInput() -> (key: [UInt8], keyId: Int32) {
        var key = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, key.count, &key)
        var idBytes = [UInt8](repeating: 0, count: 4)
        _ = SecRandomCopyBytes(kSecRandomDefault, idBytes.count, &idBytes)
        let id = (Int32(idBytes[0] & 0x7f) << 24) | (Int32(idBytes[1]) << 16) | (Int32(idBytes[2]) << 8) | Int32(idBytes[3])
        return (key, id)
    }
}
