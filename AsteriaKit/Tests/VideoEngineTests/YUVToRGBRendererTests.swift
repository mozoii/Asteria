import Testing
import Foundation
import Metal
import CoreVideo
@testable import VideoEngine

/// Offscreen CSC: NV12 → rgba16Float via BT.709 limited-range kernel; tests verify YCbCr→RGB math.
@Suite("YUV→RGB renderer (offscreen CSC)")
struct YUVToRGBRendererTests {

    /// Solid-colour NV12 (video-range 4:2:0 biplanar) pixel buffer, Metal-compatible.
    static func makeNV12(width: Int, height: Int, y: UInt8, cb: UInt8, cr: UInt8) -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [String: Any](),
        ]
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                         kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                         attrs as CFDictionary, &pb)
        let buffer = pb!
        precondition(status == kCVReturnSuccess)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        let yBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)
        let yBPR = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        for row in 0..<height { for col in 0..<width { yBase[row * yBPR + col] = y } }

        let cBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!.assumingMemoryBound(to: UInt8.self)
        let cBPR = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        for row in 0..<height / 2 {
            for col in 0..<width / 2 { cBase[row * cBPR + col * 2] = cb; cBase[row * cBPR + col * 2 + 1] = cr }
        }
        return buffer
    }

    /// Solid-colour 10-bit (x420) buffer; samples sit in the high 10 bits of each 16-bit word.
    static func make10bit(width: Int, height: Int, y: UInt16, cb: UInt16, cr: UInt16) -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [String: Any](),
        ]
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                         kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                                         attrs as CFDictionary, &pb)
        let buffer = pb!
        precondition(status == kCVReturnSuccess)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        let yBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt16.self)
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) / 2
        for row in 0..<height { for col in 0..<width { yBase[row * yStride + col] = y << 6 } }

        let cBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!.assumingMemoryBound(to: UInt16.self)
        let cStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1) / 2
        for row in 0..<height / 2 {
            for col in 0..<width / 2 { cBase[row * cStride + col * 2] = cb << 6; cBase[row * cStride + col * 2 + 1] = cr << 6 }
        }
        return buffer
    }

    /// Run the offscreen CSC into a CPU-readable rgba16Float texture so tests can sample the result.
    static func render(_ buffer: CVPixelBuffer) throws -> MTLTexture {
        let context = try MetalRenderContext()
        let renderer = try YUVToRGBRenderer(context: context)
        let output = try PresentTestSupport.shared(context, pixelFormat: .rgba16Float,
                                                   width: CVPixelBufferGetWidth(buffer),
                                                   height: CVPixelBufferGetHeight(buffer),
                                                   usage: [.shaderRead, .shaderWrite])
        let commandBuffer = try #require(context.commandQueue.makeCommandBuffer())
        try renderer.encode(YUVFrameTextures(buffer, context: context), into: output, in: commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return output
    }

    static func render10bit(y: UInt16, cb: UInt16, cr: UInt16) throws -> (r: Float, g: Float, b: Float, a: Float) {
        let texture = try render(make10bit(width: 64, height: 64, y: y, cb: cb, cr: cr))
        #expect(texture.width == 64 && texture.height == 64)
        return readPixel(texture, x: 32, y: 32)
    }

    static func readPixel(_ texture: MTLTexture, x: Int, y: Int) -> (r: Float, g: Float, b: Float, a: Float) {
        var halfs = [UInt16](repeating: 0, count: 4)
        texture.getBytes(&halfs, bytesPerRow: 4 * MemoryLayout<UInt16>.size,
                         from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0)
        func f(_ i: Int) -> Float { Float(Float16(bitPattern: halfs[i])) }
        return (f(0), f(1), f(2), f(3))
    }

    static func renderSolid(y: UInt8, cb: UInt8, cr: UInt8) throws -> (r: Float, g: Float, b: Float, a: Float) {
        let texture = try render(makeNV12(width: 64, height: 64, y: y, cb: cb, cr: cr))
        #expect(texture.width == 64 && texture.height == 64)
        return readPixel(texture, x: 32, y: 32)
    }

    @Test("video-range white (Y=235, Cb=Cr=128) → ~(1,1,1)")
    func white() throws {
        let p = try Self.renderSolid(y: 235, cb: 128, cr: 128)
        #expect(abs(p.r - 1) < 0.02 && abs(p.g - 1) < 0.02 && abs(p.b - 1) < 0.02)
        #expect(abs(p.a - 1) < 0.001)
    }

    @Test("video-range black (Y=16) → ~(0,0,0)")
    func black() throws {
        let p = try Self.renderSolid(y: 16, cb: 128, cr: 128)
        #expect(p.r < 0.02 && p.g < 0.02 && p.b < 0.02)
    }

    @Test("mid-luma (Y=126, neutral chroma) → ~0.5 grey")
    func gray() throws {
        let p = try Self.renderSolid(y: 126, cb: 128, cr: 128)
        #expect(abs(p.r - 0.502) < 0.02 && abs(p.g - 0.502) < 0.02 && abs(p.b - 0.502) < 0.02)
    }

    @Test("high Cr drives a red-dominant pixel (chroma plane + matrix)")
    func chromaRed() throws {
        let p = try Self.renderSolid(y: 128, cb: 128, cr: 200)
        #expect(p.r > 0.95)                       // high Cr saturates R
        #expect(abs(p.g - 0.36) < 0.03)
        #expect(abs(p.b - 0.51) < 0.03)
        #expect(p.r > p.b && p.b > p.g)
    }

    @Test("a BT.601-tagged frame uses BT.601 coefficients (greener than BT.709)")
    func bt601Tagged() throws {
        let buffer = Self.makeNV12(width: 64, height: 64, y: 128, cb: 128, cr: 200)
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey,
                              kCVImageBufferYCbCrMatrix_ITU_R_601_4, .shouldPropagate)
        let p = Self.readPixel(try Self.render(buffer), x: 32, y: 32)
        // BT.601 matrix differs from BT.709 (tested above).
        #expect(abs(p.r - 0.962) < 0.03)
        #expect(abs(p.g - 0.282) < 0.03)
    }

    @Test("10-bit video-range white (Y=940) → ~(1,1,1)")
    func tenBitWhite() throws {
        let p = try Self.render10bit(y: 940, cb: 512, cr: 512)
        #expect(abs(p.r - 1) < 0.02 && abs(p.g - 1) < 0.02 && abs(p.b - 1) < 0.02)
    }

    @Test("10-bit mid-luma (Y=502, neutral chroma) → ~0.5 grey")
    func tenBitGray() throws {
        let p = try Self.render10bit(y: 502, cb: 512, cr: 512)
        #expect(abs(p.r - 0.502) < 0.02 && abs(p.g - 0.502) < 0.02 && abs(p.b - 0.502) < 0.02)
    }

    @Test("10-bit black (Y=64) → ~(0,0,0)")
    func tenBitBlack() throws {
        let p = try Self.render10bit(y: 64, cb: 512, cr: 512)
        #expect(p.r < 0.02 && p.g < 0.02 && p.b < 0.02)
    }

    @Test("10-bit high Cr drives a red-dominant pixel")
    func tenBitChromaRed() throws {
        let p = try Self.render10bit(y: 512, cb: 512, cr: 800)
        #expect(p.r > p.b && p.b > p.g)
    }

    @Test("a real decoded Sunshine frame converts to a full-size, non-black rgba texture")
    func realFrame() async throws {
        let url = try #require(
            Bundle.module.url(forResource: "sunshine-hevc-keyframe", withExtension: "bin", subdirectory: "Fixtures"))
        let annexB = Array(try Data(contentsOf: url))
        let holder = LatestFrameHolder()
        let decoder = VideoDecoder(codec: .hevc, holder: holder)
        #expect(await decoder.submit(annexB: annexB, frameIndex: 1) == .ok)
        await decoder.waitForFrames()
        let buffer = try #require(holder.peek()?.buffer)

        let texture = try Self.render(buffer)
        #expect(texture.width == 1920 && texture.height == 1080)

        // At least one sample is meaningfully bright.
        let brightest = (0..<16).map { i -> Float in
            let p = Self.readPixel(texture, x: 120 * i, y: 67 * i)
            return max(p.r, p.g, p.b)
        }.max() ?? 0
        #expect(brightest > 0.1)
        await decoder.stop()
    }
}
