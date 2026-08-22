import Testing
import GameStreamProtocol
import VideoEngine
import AudioEngine
import InputEngine
@testable import LiveSession

@Suite("StreamTelemetry aggregate")
struct StreamTelemetryTests {
    @Test("equates field-by-field and a single changed counter breaks equality")
    func equatable() {
        var input = InputStats(); input.eventsEnqueued = 12; input.packetsSent = 3
        var control = InboundControlCounts(); control.rumble = 2

        let a = StreamTelemetry(input: input, control: control,
                                referenceInvalidationEnabled: true, lastSDP: "v=0")
        let b = StreamTelemetry(input: input, control: control,
                                referenceInvalidationEnabled: true, lastSDP: "v=0")
        #expect(a == b)

        var bumped = input; bumped.packetsSent = 4
        let c = StreamTelemetry(input: bumped, control: control,
                                referenceInvalidationEnabled: true, lastSDP: "v=0")
        #expect(a != c)

        let d = StreamTelemetry(input: input, control: control,
                                referenceInvalidationEnabled: false, lastSDP: "v=0")
        #expect(a != d)
    }

    @Test("description surfaces the headline figures")
    func description() {
        var input = InputStats(); input.packetsSent = 7
        var video = RTPStreamReceiver<AssembledFrame>.Stats(); video.outputs = 5
        let t = StreamTelemetry(videoTransport: video, input: input)
        let line = "\(t)"
        #expect(line.contains("video 5f"))
        #expect(line.contains("input 7pkts"))
    }

    @Test("description surfaces audio decode and render health")
    func audioDescription() {
        var audio = AudioStats()
        audio.packetsDecoded = 42
        audio.concealed = 3
        audio.render.underruns = 1
        audio.render.overruns = 2
        let line = "\(StreamTelemetry(audio: audio))"
        #expect(line.contains("42dec/3plc/1ur/2or"))
    }
}
