import Testing
import Foundation
import CoreGraphics
@testable import VideoEngine

/// The render-thread HDR reconcile: `setHdrMode` flips the layer live, and HDR10 metadata is adopted from the
/// first SEI-bearing frame. Drives `applyHDRState` directly (the frame path calls it) without a display link.
@Suite("Live HDR reconcile")
struct MetalVideoPresenterHDRTests {
    private func presenter(hdr: Bool, tenBit: Bool) throws -> MetalVideoPresenter {
        try MetalVideoPresenter(holder: LatestFrameHolder(), initialSize: CGSize(width: 64, height: 64),
                                options: PresentOptions(streamFps: 60, displayMaxHz: nil,
                                                        enableMetalFX: false, hdr: hdr), tenBit: tenBit)
    }

    @Test("setHdrMode flips layer tagging on, adopts metadata, then clears it on disable")
    func reconcileOnOff() throws {
        let p = try presenter(hdr: false, tenBit: true)
        #expect(p.metalLayer.colorspace?.name == CGColorSpace.sRGB)   // starts SDR

        let frame = try PresentTestSupport.hdrPixelBuffer(width: 64, height: 64,
                                                          mastering: Data(count: 24), contentLight: Data(count: 4))
        p.setHDRActive(true)
        p.applyHDRState(for: frame)
        #expect(p.metalLayer.colorspace?.name == CGColorSpace.itur_2100_PQ)
        #expect(p.metalLayer.wantsExtendedDynamicRangeContent)
        #expect(p.metalLayer.edrMetadata != nil)

        p.setHDRActive(false)
        p.applyHDRState(for: frame)
        #expect(p.metalLayer.colorspace?.name == CGColorSpace.sRGB)
        #expect(!p.metalLayer.wantsExtendedDynamicRangeContent)
        #expect(p.metalLayer.edrMetadata == nil)
    }

    @Test("HDR10 metadata is adopted only once a frame carrying the SEI arrives")
    func metadataAwaitsSEI() throws {
        let p = try presenter(hdr: true, tenBit: true)
        let bare = try PresentTestSupport.hdrPixelBuffer(width: 64, height: 64, mastering: nil, contentLight: nil)
        p.applyHDRState(for: bare)
        #expect(p.metalLayer.colorspace?.name == CGColorSpace.itur_2100_PQ)   // PQ from the first frame
        #expect(p.metalLayer.edrMetadata == nil)                              // metadata not yet present

        let full = try PresentTestSupport.hdrPixelBuffer(width: 64, height: 64,
                                                         mastering: Data(count: 24), contentLight: Data(count: 4))
        p.applyHDRState(for: full)
        #expect(p.metalLayer.edrMetadata != nil)                              // adopted on the SEI frame
    }

    @Test("setHdrMode is ignored on an SDR (non-10-bit) stream")
    func gatedByTenBit() throws {
        let p = try presenter(hdr: false, tenBit: false)
        let frame = try PresentTestSupport.hdrPixelBuffer(width: 64, height: 64,
                                                          mastering: Data(count: 24), contentLight: Data(count: 4))
        p.setHDRActive(true)
        p.applyHDRState(for: frame)
        #expect(p.metalLayer.colorspace?.name == CGColorSpace.sRGB)   // gate keeps it SDR
    }
}
