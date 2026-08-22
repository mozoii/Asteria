import Testing
import Foundation
import Metal
import CoreGraphics
@testable import VideoEngine

/// Present pass: layer/target format selection and the fullscreen-triangle passthrough (no-dither identity).
@Suite("Present renderer + layer format")
struct PresentRendererTests {
    @Test("EDR metadata is built only when both HDR SEI attachments are present")
    func edrMetadataMapping() {
        let mdcv = Data(count: 24)   // ST 2086 mastering display colour volume
        let cll = Data(count: 4)     // content light level (MaxCLL/MaxFALL)
        #expect(MetalVideoPresenter.edrMetadata(masteringDisplay: mdcv, contentLight: cll) != nil)
        #expect(MetalVideoPresenter.edrMetadata(masteringDisplay: nil, contentLight: cll) == nil)
        #expect(MetalVideoPresenter.edrMetadata(masteringDisplay: mdcv, contentLight: nil) == nil)
    }

    @Test("an HDR presenter tags the layer PQ + EDR; SDR stays sRGB")
    func presenterHDRTagging() throws {
        let holder = LatestFrameHolder()
        let size = CGSize(width: 64, height: 64)
        let hdr = try MetalVideoPresenter(holder: holder, initialSize: size,
                                          options: PresentOptions(streamFps: 60, displayMaxHz: nil,
                                                                  enableMetalFX: false, hdr: true), tenBit: true)
        #expect(hdr.metalLayer.colorspace?.name == CGColorSpace.itur_2100_PQ)
        #expect(hdr.metalLayer.wantsExtendedDynamicRangeContent)
        let sdr = try MetalVideoPresenter(holder: holder, initialSize: size,
                                          options: PresentOptions(streamFps: 60, displayMaxHz: nil,
                                                                  enableMetalFX: false, hdr: false), tenBit: true)
        #expect(sdr.metalLayer.colorspace?.name == CGColorSpace.sRGB)
        #expect(!sdr.metalLayer.wantsExtendedDynamicRangeContent)
    }

    @Test("HDR is refused on an SDR (non-10-bit) stream even when requested")
    func presenterHDRGatedByTenBit() throws {
        let holder = LatestFrameHolder()
        let presenter = try MetalVideoPresenter(holder: holder, initialSize: CGSize(width: 64, height: 64),
                                                options: PresentOptions(streamFps: 60, displayMaxHz: nil,
                                                                        enableMetalFX: false, hdr: true),
                                                tenBit: false)
        #expect(presenter.metalLayer.colorspace?.name == CGColorSpace.sRGB)
        #expect(!presenter.metalLayer.wantsExtendedDynamicRangeContent)
    }

    @Test("a 10-bit presenter uses a bgr10a2 layer; 8-bit uses bgra8")
    func presenterLayerFormat() throws {
        let holder = LatestFrameHolder()
        let size = CGSize(width: 64, height: 64)
        let tenBit = try MetalVideoPresenter(holder: holder, initialSize: size,
                                             options: PresentOptions(streamFps: 60, displayMaxHz: nil,
                                                                     enableMetalFX: false), tenBit: true)
        #expect(tenBit.metalLayer.pixelFormat == .bgr10a2Unorm)
        let eightBit = try MetalVideoPresenter(holder: holder, initialSize: size,
                                               options: PresentOptions(streamFps: 60, displayMaxHz: nil,
                                                                       enableMetalFX: false), tenBit: false)
        #expect(eightBit.metalLayer.pixelFormat == .bgra8Unorm)
    }

    @Test("no-dither present passes the source through unchanged")
    func presentIdentity() throws {
        let context = try MetalRenderContext()
        let renderer = try PresentRenderer(context: context, pixelFormat: .bgra8Unorm, dither: false)
        let source = try PresentTestSupport.solid(context, width: 16, height: 16,
                                                  rgba: SIMD4<Float>(0.5, 0.25, 0.75, 1))
        let target = try PresentTestSupport.renderTarget(context, pixelFormat: .bgra8Unorm, width: 16, height: 16)
        let commandBuffer = try #require(context.commandQueue.makeCommandBuffer())
        try renderer.encode(source: source, into: target, in: commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        let r = PresentTestSupport.readRow8(target, y: 8)[8]
        #expect(abs(r - 0.5) < 1.0 / 255.0)
    }
}
