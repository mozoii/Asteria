import Testing
import Metal
@testable import VideoEngine

/// Spatial upscaler: MetalFX scales CSC output to target size; headless tests prove correct scaling and flat-color preservation.
@Suite("Spatial upscaler (MetalFX)")
struct SpatialUpscalerTests {
    static func filledTexture(_ context: MetalRenderContext, width: Int, height: Int, value: Float16,
                              usage: MTLTextureUsage) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
        descriptor.usage = usage
        descriptor.storageMode = .shared
        let texture = context.device.makeTexture(descriptor: descriptor)!
        var pixels = [Float16](repeating: value, count: width * height * 4)
        for i in 0..<(width * height) { pixels[i * 4 + 3] = 1 }   // alpha channel
        pixels.withUnsafeBytes { raw in
            texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                            withBytes: raw.baseAddress!, bytesPerRow: width * 4 * MemoryLayout<Float16>.size)
        }
        return texture
    }

    static func readPixel(_ texture: MTLTexture, x: Int, y: Int) -> (r: Float, g: Float, b: Float) {
        var halfs = [UInt16](repeating: 0, count: 4)
        texture.getBytes(&halfs, bytesPerRow: 4 * MemoryLayout<UInt16>.size,
                         from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0)
        // halfs[0]=R, halfs[1]=G, halfs[2]=B.
        return (Float(Float16(bitPattern: halfs[0])), Float(Float16(bitPattern: halfs[1])), Float(Float16(bitPattern: halfs[2])))
    }

    @Test("upscales to the target size and preserves a flat colour")
    func upscalesSolid() throws {
        let context = try MetalRenderContext()
        try #require(SpatialUpscaler.isSupported(device: context.device))

        let upscaler = try SpatialUpscaler(context: context,
                                           inputWidth: 64, inputHeight: 64, outputWidth: 128, outputHeight: 128)
        #expect(upscaler.outputWidth == 128 && upscaler.outputHeight == 128)

        let input = try Self.filledTexture(context, width: 64, height: 64, value: 0.5,
                                           usage: [.shaderRead, .shaderWrite])
        let output = try Self.filledTexture(context, width: 128, height: 128, value: 0,
                                            usage: [.shaderRead, .shaderWrite, .renderTarget])
        let commandBuffer = context.commandQueue.makeCommandBuffer()!
        upscaler.encode(input: input, output: output, in: commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        #expect(output.width == 128 && output.height == 128)
        let p = Self.readPixel(output, x: 64, y: 64)
        #expect(abs(p.r - 0.5) < 0.05 && abs(p.g - 0.5) < 0.05 && abs(p.b - 0.5) < 0.05)
    }
}
