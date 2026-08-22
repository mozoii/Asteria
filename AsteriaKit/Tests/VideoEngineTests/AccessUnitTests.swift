import Testing
@testable import VideoEngine

@Suite("Access-unit splitting")
struct AccessUnitTests {
    private let sc: [UInt8] = [0, 0, 0, 1]   // 4-byte start code

    @Test("H.264 keyframe: SPS/PPS → params, IDR → sample, isKeyframe")
    func h264Keyframe() {
        let au = sc + [0x67, 0x11] + sc + [0x68, 0x22] + sc + [0x65, 0x33, 0x44]
        let split = AccessUnit.split(au, codec: .h264)
        #expect(split.parameterSets.map { Array($0) } == [[0x67, 0x11], [0x68, 0x22]])
        #expect(split.sampleNALs.map { Array($0) } == [[0x65, 0x33, 0x44]])
        #expect(split.isKeyframe)
    }

    @Test("H.264 non-keyframe: only a non-IDR slice, no params")
    func h264NonKeyframe() {
        let au = sc + [0x41, 0x09, 0x10]
        let split = AccessUnit.split(au, codec: .h264)
        #expect(split.parameterSets.isEmpty)
        #expect(split.sampleNALs.map { Array($0) } == [[0x41, 0x09, 0x10]])
        #expect(!split.isKeyframe)
    }

    @Test("SEI is kept in the sample NALs, not treated as a parameter set")
    func keepsSEI() {
        let au = sc + [0x67, 0x11] + sc + [0x06, 0xAA] + sc + [0x65, 0x33]   // SPS, SEI, IDR
        let split = AccessUnit.split(au, codec: .h264)
        #expect(split.parameterSets.map { Array($0) } == [[0x67, 0x11]])
        #expect(split.sampleNALs.map { Array($0) } == [[0x06, 0xAA], [0x65, 0x33]])
        #expect(split.isKeyframe)
    }

    @Test("HEVC keyframe: VPS/SPS/PPS → params, IDR_W_RADL → sample")
    func hevcKeyframe() {
        let au = sc + [0x40, 0x01] + sc + [0x42, 0x01] + sc + [0x44, 0x01] + sc + [0x26, 0x01, 0x99]
        let split = AccessUnit.split(au, codec: .hevc)
        #expect(split.parameterSets.map { Array($0) } == [[0x40, 0x01], [0x42, 0x01], [0x44, 0x01]])
        #expect(split.sampleNALs.map { Array($0) } == [[0x26, 0x01, 0x99]])
        #expect(split.isKeyframe)
    }

    // Sunshine frame header with false 3-byte start code (f0003 capture); naive scan emits phantom HEVC type 60.
    private let phantomHeader: [UInt8] = [0x01, 0x00, 0x00, 0x01, 0xf9, 0x01, 0x00, 0x00]

    @Test("bitstream() skips the frame header to the real 4-byte start code")
    func bitstreamStripsHeader() {
        let frame = phantomHeader + sc + [0x02, 0x01, 0xAA]
        #expect(AccessUnit.bitstream(frame) == sc + [0x02, 0x01, 0xAA])
        #expect(AccessUnit.bitstream(sc + [0x67]) == sc + [0x67])
        #expect(AccessUnit.bitstream([0, 0, 1, 0x41]) == [0, 0, 1, 0x41])
    }

    @Test("split ignores the frame header's phantom start code — only the real slice survives")
    func splitDropsPhantomNAL() {
        let frame = phantomHeader + sc + [0x02, 0x01, 0xAA, 0xBB]   // HEVC type 1 = TRAIL_R
        let split = AccessUnit.split(frame, codec: .hevc)
        #expect(split.parameterSets.isEmpty)
        #expect(split.sampleNALs.map { Array($0) } == [[0x02, 0x01, 0xAA, 0xBB]])
        #expect(!split.isKeyframe)
    }
}
