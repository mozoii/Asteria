import Metal
import CoreVideo

/// Zero-copy Metal wrapping of a decoded frame's luma/chroma planes plus the YCbCr→RGB constants for its colour tag.
/// Shared by the offscreen CSC compute path and the fused single-pass present path.
struct YUVFrameTextures {
    let luma: MTLTexture
    let chroma: MTLTexture
    let coefficients: SIMD4<Float>
    /// (black level, luma range, chroma centre, chroma range) in code units.
    let levels: SIMD4<Float>
    /// Multiplier turning a texture-normalized read into code units.
    let codeScale: Float

    init(_ pixelBuffer: CVPixelBuffer, context: MetalRenderContext) throws {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let plane = PlaneFormat(CVPixelBufferGetPixelFormatType(pixelBuffer))
        luma = try context.planeTexture(pixelBuffer, plane: 0, format: plane.luma, width: width, height: height)
        chroma = try context.planeTexture(pixelBuffer, plane: 1, format: plane.chroma,
                                          width: width / 2, height: height / 2)
        coefficients = ColorCoefficients.forPixelBuffer(pixelBuffer).simd
        levels = plane.levels
        codeScale = plane.codeScale
    }
}

/// Per-pixel-format plane formats and YCbCr→full-range expansion constants.
struct PlaneFormat {
    let luma: MTLPixelFormat
    let chroma: MTLPixelFormat
    /// Multiplier turning a texture-normalized read into code units (10-bit samples sit in the high 10 of 16 bits).
    let codeScale: Float
    /// (black level, luma range, chroma centre, chroma range) in code units.
    let levels: SIMD4<Float>

    init(_ format: OSType) {
        switch format {
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange:
            luma = .r16Unorm; chroma = .rg16Unorm; codeScale = 65535.0 / 64.0
            levels = SIMD4(64, 876, 512, 896)
        case kCVPixelFormatType_420YpCbCr10BiPlanarFullRange:
            luma = .r16Unorm; chroma = .rg16Unorm; codeScale = 65535.0 / 64.0
            levels = SIMD4(0, 1023, 512, 1023)
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            luma = .r8Unorm; chroma = .rg8Unorm; codeScale = 255
            levels = SIMD4(0, 255, 128, 255)
        default:
            luma = .r8Unorm; chroma = .rg8Unorm; codeScale = 255
            levels = SIMD4(16, 219, 128, 224)
        }
    }
}
