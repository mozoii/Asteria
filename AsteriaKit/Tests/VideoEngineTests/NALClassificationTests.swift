import Testing
@testable import VideoEngine

@Suite("NAL classification")
struct NALClassificationTests {
    // H.264 first byte: forbidden_zero(1) nal_ref_idc(2) nal_unit_type(5).
    @Test("H.264 categories from nal_unit_type")
    func h264Categories() {
        #expect(H264NAL.category(of: [0x67][...]) == .sps)      // type 7
        #expect(H264NAL.category(of: [0x68][...]) == .pps)      // type 8
        #expect(H264NAL.category(of: [0x65][...]) == .idr)      // type 5
        #expect(H264NAL.category(of: [0x41][...]) == .nonIdr)   // type 1
        #expect(H264NAL.category(of: [0x06][...]) == .other)    // type 6 (SEI)
    }

    // HEVC byte0: forbidden_zero(1) nal_unit_type(6); type = (byte0 >> 1) & 0x3F.
    @Test("HEVC categories from nal_unit_type")
    func hevcCategories() {
        #expect(HEVCNAL.category(of: [0x40, 0x01][...]) == .vps)     // type 32
        #expect(HEVCNAL.category(of: [0x42, 0x01][...]) == .sps)     // type 33
        #expect(HEVCNAL.category(of: [0x44, 0x01][...]) == .pps)     // type 34
        #expect(HEVCNAL.category(of: [0x26, 0x01][...]) == .idr)     // type 19 (IDR_W_RADL)
        #expect(HEVCNAL.category(of: [0x2A, 0x01][...]) == .idr)     // type 21 (CRA_NUT, IRAP)
        #expect(HEVCNAL.category(of: [0x02, 0x01][...]) == .nonIdr)  // type 1 (TRAIL_R)
        #expect(HEVCNAL.category(of: [0x4E, 0x01][...]) == .other)   // type 39 (SEI_PREFIX)
    }

    @Test("type extraction")
    func typeExtraction() {
        #expect(H264NAL.type(of: [0x67][...]) == 7)
        #expect(HEVCNAL.type(of: [0x42, 0x01][...]) == 33)
    }
}
