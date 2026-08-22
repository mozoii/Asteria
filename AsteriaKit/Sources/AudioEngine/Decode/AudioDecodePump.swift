import Foundation
import GameStreamProtocol

/// Decodes ordered Opus packets inline on the receiver task; single-consumer — never call `ingest` concurrently.
public final class AudioDecodePump: @unchecked Sendable {
    private let decoder: OpusAudioDecoder
    private let remap: ChannelRemap
    private let renderer: AudioRenderer
    private let stats: AudioStatsTracker
    /// Cap on consecutive concealment frames before giving up on a gap and letting the ring resync.
    private let maxConcealedFrames: Int
    private var expectedSequence: UInt16?
    private var loggedDecodeFailure = false

    public init(decoder: OpusAudioDecoder, remap: ChannelRemap, renderer: AudioRenderer,
                stats: AudioStatsTracker, maxConcealedFrames: Int = 8) {
        self.decoder = decoder
        self.remap = remap
        self.renderer = renderer
        self.stats = stats
        self.maxConcealedFrames = maxConcealedFrames
    }

    public func ingest(_ packet: AudioOpusPacket) {
        if let expected = expectedSequence {
            let gap = Int(Int16(bitPattern: packet.sequenceNumber &- expected))
            if gap < 0 { stats.recordDropped(1); return }
            if gap > 0 {
                let conceal = min(gap, maxConcealedFrames)
                for _ in 0..<conceal {
                    if let pcm = try? decoder.concealLoss() { renderer.render(remap.remap(pcm)) }
                }
                stats.recordConcealed(conceal)
                if gap > maxConcealedFrames { stats.recordDropped(gap - maxConcealedFrames) }
            }
        }

        expectedSequence = packet.sequenceNumber &+ 1
        let pcm: [Float]
        do {
            pcm = try decoder.decode(packet.data)
        } catch {
            if !loggedDecodeFailure {
                loggedDecodeFailure = true
                FileHandle.standardError.write(Data("audio pump: decode failed: \(error) (packet bytes=\(packet.data.count))\n".utf8))
            }
            return
        }
        renderer.render(remap.remap(pcm))
        stats.recordDecoded(samples: pcm.count / max(1, remap.channelCount))
        if packet.recovered { stats.recordFecRecovered() }
    }
}
