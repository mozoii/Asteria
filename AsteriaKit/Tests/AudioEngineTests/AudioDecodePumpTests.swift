import Testing
import GameStreamProtocol
@testable import AudioEngine

@Suite("AudioDecodePump")
struct AudioDecodePumpTests {
    /// Records every PCM buffer pushed through the renderer seam.
    final class RecordingRenderer: AudioRenderer, @unchecked Sendable {
        nonisolated(unsafe) var buffers: [[Float]] = []
        func start(format: AudioRenderFormat) {}
        func render(_ pcm: [Float]) { buffers.append(pcm) }
        func stop() {}
        func renderStats() -> AudioRenderStats { AudioRenderStats() }
    }

    static func makePump(_ renderer: AudioRenderer, _ stats: AudioStatsTracker) throws -> AudioDecodePump {
        let decoder = try OpusAudioDecoder(channelCount: 2, streams: 1, coupledStreams: 1,
                                           mapping: [0, 1], samplesPerFrame: 480)
        return AudioDecodePump(decoder: decoder, remap: ChannelRemap(channelCount: 2)!,
                               renderer: renderer, stats: stats)
    }

    static func packet(_ data: [UInt8], seq: UInt16, recovered: Bool = false) -> AudioOpusPacket {
        AudioOpusPacket(sequenceNumber: seq, data: data, recovered: recovered)
    }

    @Test func decodesOrderedPacketsToRenderer() throws {
        let packets = OpusAudioDecoderTests.encodeStereoSine(frames: 4)
        let renderer = RecordingRenderer()
        let stats = AudioStatsTracker()
        let pump = try Self.makePump(renderer, stats)
        for (i, data) in packets.enumerated() { pump.ingest(Self.packet(data, seq: UInt16(i))) }

        #expect(renderer.buffers.count == 4)
        #expect(renderer.buffers.allSatisfy { $0.count == 480 * 2 })
        let snapshot = stats.snapshot()
        #expect(snapshot.packetsDecoded == 4)
        #expect(snapshot.samplesDecoded == 480 * 4)
        #expect(snapshot.concealed == 0)
    }

    @Test func concealsUnrecoveredGap() throws {
        let packets = OpusAudioDecoderTests.encodeStereoSine(frames: 4)
        let renderer = RecordingRenderer()
        let stats = AudioStatsTracker()
        let pump = try Self.makePump(renderer, stats)
        pump.ingest(Self.packet(packets[0], seq: 10))
        pump.ingest(Self.packet(packets[1], seq: 13))   // seq 11, 12 missing

        #expect(stats.snapshot().concealed == 2)
        #expect(renderer.buffers.count == 4)            // 1 decoded + 2 concealed + 1 decoded
        #expect(stats.snapshot().packetsDecoded == 2)
    }

    @Test func dropsLateOrDuplicatePackets() throws {
        let packets = OpusAudioDecoderTests.encodeStereoSine(frames: 3)
        let renderer = RecordingRenderer()
        let stats = AudioStatsTracker()
        let pump = try Self.makePump(renderer, stats)
        pump.ingest(Self.packet(packets[0], seq: 5))
        pump.ingest(Self.packet(packets[1], seq: 6))
        pump.ingest(Self.packet(packets[2], seq: 5))    // older than expected (7) -> dropped

        #expect(stats.snapshot().packetsDecoded == 2)
        #expect(stats.snapshot().dropped == 1)
        #expect(renderer.buffers.count == 2)
    }

    @Test func countsFecRecoveredPackets() throws {
        let packets = OpusAudioDecoderTests.encodeStereoSine(frames: 2)
        let renderer = RecordingRenderer()
        let stats = AudioStatsTracker()
        let pump = try Self.makePump(renderer, stats)
        pump.ingest(Self.packet(packets[0], seq: 0))
        pump.ingest(Self.packet(packets[1], seq: 1, recovered: true))
        #expect(stats.snapshot().fecRecovered == 1)
    }
}
