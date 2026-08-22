import Testing
import Metal
@testable import VideoEngine

/// Single-pass CSC + dither straight into the drawable (no intermediate): verifies the fused path reproduces the
/// two-pass YCbCr→RGB math and honours the target pixel format.
@Suite("Fused present renderer (CSC direct to drawable)")
struct FusedPresentRendererTests {
    /// Render a solid NV12 buffer through the fused renderer into a fresh target and return the centre row's R values.
    static func present(y: UInt8, cb: UInt8, cr: UInt8,
                        pixelFormat: MTLPixelFormat = .bgra8Unorm, dither: Bool = false) throws -> [Float] {
        let context = try MetalRenderContext()
        let renderer = try FusedPresentRenderer(context: context, pixelFormat: pixelFormat, dither: dither)
        let buffer = YUVToRGBRendererTests.makeNV12(width: 64, height: 64, y: y, cb: cb, cr: cr)
        let frame = try YUVFrameTextures(buffer, context: context)
        let target = try PresentTestSupport.renderTarget(context, pixelFormat: pixelFormat, width: 64, height: 64)
        let commandBuffer = try #require(context.commandQueue.makeCommandBuffer())
        try renderer.encode(frame, into: target, in: commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return pixelFormat == .bgr10a2Unorm ? PresentTestSupport.readRow10(target, y: 32)
                                            : PresentTestSupport.readRow8(target, y: 32)
    }

    @Test("video-range white (Y=235, neutral chroma) → R≈1")
    func white() throws {
        let r = try Self.present(y: 235, cb: 128, cr: 128)[32]
        #expect(abs(r - 1) < 0.02)
    }

    @Test("video-range black (Y=16) → R≈0")
    func black() throws {
        let r = try Self.present(y: 16, cb: 128, cr: 128)[32]
        #expect(r < 0.02)
    }

    @Test("mid-luma (Y=126, neutral chroma) → R≈0.5")
    func gray() throws {
        let r = try Self.present(y: 126, cb: 128, cr: 128)[32]
        #expect(abs(r - 0.502) < 0.02)
    }

    @Test("high Cr saturates R")
    func chromaRed() throws {
        let r = try Self.present(y: 128, cb: 128, cr: 200)[32]
        #expect(r > 0.95)
    }

    @Test("10-bit target carries the CSC result (white → R≈1)")
    func tenBitWhite() throws {
        let r = try Self.present(y: 235, cb: 128, cr: 128, pixelFormat: .bgr10a2Unorm)[32]
        #expect(abs(r - 1) < 0.02)
    }

    @Test("dither perturbs a flat region within ±1 LSB at 10-bit")
    func ditherSpreadsFlatRegion() throws {
        let undithered = try Self.present(y: 126, cb: 128, cr: 128, pixelFormat: .bgr10a2Unorm, dither: false)
        let base = Int((undithered[0] * 1023).rounded())
        let dithered = try Self.present(y: 126, cb: 128, cr: 128, pixelFormat: .bgr10a2Unorm, dither: true)
        let codes = dithered.map { Int(($0 * 1023).rounded()) }
        #expect(codes.allSatisfy { abs($0 - base) <= 1 })
        #expect(Set(codes).count >= 2)
    }
}
