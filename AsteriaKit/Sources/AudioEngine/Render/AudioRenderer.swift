import Synchronization
import CoreAudioTypes

/// Output format handed to a renderer at start.
public struct AudioRenderFormat: Sendable, Equatable {
    public let sampleRate: Int
    public let channelCount: Int
    public let layoutTag: AudioChannelLayoutTag

    public init(sampleRate: Int, channelCount: Int, layoutTag: AudioChannelLayoutTag) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.layoutTag = layoutTag
    }
}

/// Render-thread health from the consumer side of the PCM ring.
public struct AudioRenderStats: Sendable, Equatable {
    public var underruns = 0
    public var overruns = 0
    public var droppedSamples = 0
    public var depth = 0
    public init() {}
    public init(underruns: Int, overruns: Int, droppedSamples: Int, depth: Int) {
        self.underruns = underruns
        self.overruns = overruns
        self.droppedSamples = droppedSamples
        self.depth = depth
    }
}

/// Render seam: the decode pump pushes interleaved PCM via `render`, called inline on the receiver task.
public protocol AudioRenderer: Sendable {
    func start(format: AudioRenderFormat) async throws
    func render(_ pcm: [Float])
    func stop() async
    func renderStats() -> AudioRenderStats
}

/// No-op renderer: accepts PCM but produces no sound; counts what it received for validation.
public final class NullRenderer: AudioRenderer, @unchecked Sendable {
    private let samples = Atomic<Int>(0)
    private let frames = Atomic<Int>(0)

    public init() {}

    public func start(format: AudioRenderFormat) {}
    public func render(_ pcm: [Float]) {
        samples.wrappingAdd(pcm.count, ordering: .relaxed)
        frames.wrappingAdd(1, ordering: .relaxed)
    }
    public func stop() {}
    public func renderStats() -> AudioRenderStats { AudioRenderStats() }

    public var samplesReceived: Int { samples.load(ordering: .relaxed) }
    public var framesReceived: Int { frames.load(ordering: .relaxed) }
}
