import Metal

/// YCbCr→RGB compute kernel: converts NV12 biplanar pixels to `rgba16Float` using the frame's YCbCr
/// matrix and range constants (see `YUVFrameTextures`).
public final class YUVToRGBRenderer {
    private let context: MetalRenderContext
    private let pipeline: MTLComputePipelineState

    public init(context: MetalRenderContext) throws {
        self.context = context
        let library: MTLLibrary
        do {
            library = try context.device.makeLibrary(source: Self.shaderSource, options: nil)
        } catch {
            throw MetalRenderError.libraryCompile("\(error)")
        }
        guard let function = library.makeFunction(name: "yuv_to_rgb") else {
            throw MetalRenderError.missingFunction("yuv_to_rgb")
        }
        do {
            self.pipeline = try context.device.makeComputePipelineState(function: function)
        } catch {
            throw MetalRenderError.pipeline("\(error)")
        }
    }

    /// Encode YCbCr→RGB from the frame's luma/chroma planes into `output`; caller commits and presents.
    /// Handles 8- and 10-bit biplanar input.
    func encode(_ frame: YUVFrameTextures, into output: MTLTexture, in commandBuffer: MTLCommandBuffer) throws {
        var coefficients = frame.coefficients
        var levels = frame.levels
        var codeScale = frame.codeScale
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { throw MetalRenderError.encoder }
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(frame.luma, index: 0)
        encoder.setTexture(frame.chroma, index: 1)
        encoder.setTexture(output, index: 2)
        encoder.setBytes(&coefficients, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
        encoder.setBytes(&levels, length: MemoryLayout<SIMD4<Float>>.size, index: 1)
        encoder.setBytes(&codeScale, length: MemoryLayout<Float>.size, index: 2)
        let threadgroup = MTLSize(width: 16, height: 16, depth: 1)
        let groups = MTLSize(width: (output.width + 15) / 16, height: (output.height + 15) / 16, depth: 1)
        encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: threadgroup)
        encoder.endEncoding()
    }

    /// Allocate the `.private` `rgba16Float` intermediate the MetalFX upscale path renders CSC into.
    public func makeOutputTexture(width: Int, height: Int) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        guard let texture = context.device.makeTexture(descriptor: descriptor) else {
            throw MetalRenderError.textureCreate
        }
        return texture
    }

    /// YCbCr → full-range RGB. Reads are scaled to code units (`codeScale`), then range-expanded with
    /// `levels` = (black, lumaRange, chromaCentre, chromaRange); the colour matrix uses the frame's colour tag.
    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    kernel void yuv_to_rgb(texture2d<float, access::read>  luma   [[texture(0)]],
                           texture2d<float, access::read>  chroma [[texture(1)]],
                           texture2d<float, access::write> outTex [[texture(2)]],
                           constant float4 &coeff     [[buffer(0)]],
                           constant float4 &levels    [[buffer(1)]],
                           constant float  &codeScale [[buffer(2)]],
                           uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= outTex.get_width() || gid.y >= outTex.get_height()) { return; }

        float  Y    = luma.read(gid).r * codeScale;
        float2 CbCr = chroma.read(gid / 2).rg * codeScale;

        float y = (Y - levels.x) / levels.y;
        float u = (CbCr.x - levels.z) / levels.w;
        float v = (CbCr.y - levels.z) / levels.w;

        float r = y + coeff.x * v;
        float g = y - coeff.y * u - coeff.z * v;
        float b = y + coeff.w * u;

        outTex.write(float4(clamp(float3(r, g, b), 0.0, 1.0), 1.0), gid);
    }
    """
}
