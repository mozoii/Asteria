import Metal

/// Single-pass present for the no-upscale case: one fullscreen-triangle fragment reads the decoded luma/chroma
/// planes, runs YCbCr→RGB (+ optional 10-bit dither), and writes straight into the drawable — no intermediate.
public final class FusedPresentRenderer {
    private let pipeline: MTLRenderPipelineState

    public init(context: MetalRenderContext, pixelFormat: MTLPixelFormat, dither: Bool) throws {
        let library: MTLLibrary
        do {
            library = try context.device.makeLibrary(source: Self.shaderSource, options: nil)
        } catch {
            throw MetalRenderError.libraryCompile("\(error)")
        }
        let constants = MTLFunctionConstantValues()
        var dither = dither
        constants.setConstantValue(&dither, type: .bool, index: 0)
        guard let vertex = library.makeFunction(name: "fused_vertex") else {
            throw MetalRenderError.missingFunction("fused_vertex")
        }
        let fragment: MTLFunction
        do {
            fragment = try library.makeFunction(name: "fused_fragment", constantValues: constants)
        } catch {
            throw MetalRenderError.missingFunction("fused_fragment")
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = pixelFormat
        do {
            self.pipeline = try context.device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            throw MetalRenderError.pipeline("\(error)")
        }
    }

    /// Encode CSC (+ optional dither) from `frame`'s planes straight into `target`; caller presents/commits.
    func encode(_ frame: YUVFrameTextures, into target: MTLTexture, in commandBuffer: MTLCommandBuffer) throws {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            throw MetalRenderError.encoder
        }
        var coefficients = frame.coefficients
        var levels = frame.levels
        var codeScale = frame.codeScale
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(frame.luma, index: 0)
        encoder.setFragmentTexture(frame.chroma, index: 1)
        encoder.setFragmentBytes(&coefficients, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
        encoder.setFragmentBytes(&levels, length: MemoryLayout<SIMD4<Float>>.size, index: 1)
        encoder.setFragmentBytes(&codeScale, length: MemoryLayout<Float>.size, index: 2)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    constant bool applyDither [[function_constant(0)]];

    struct VOut { float4 position [[position]]; };

    vertex VOut fused_vertex(uint vid [[vertex_id]]) {
        float2 pos[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
        VOut out;
        out.position = float4(pos[vid], 0.0, 1.0);
        return out;
    }

    // Dave Hoskins hash: pixel coordinate → uniform [0,1). No time input, so the pattern is static (no shimmer).
    static inline float hash12(float2 p) {
        float3 p3 = fract(float3(p.xyx) * 0.1031);
        p3 += dot(p3, p3.yzx + 33.33);
        return fract((p3.x + p3.y) * p3.z);
    }

    // Drawable is 1:1 with the frame, so the pixel coordinate is the luma texel index; chroma is nearest-sampled
    // at gid/2 to match the two-pass kernel. Reads are clamped so a one-frame size lag can't fetch out of range.
    fragment float4 fused_fragment(VOut in [[stage_in]],
                                   texture2d<float, access::read> luma   [[texture(0)]],
                                   texture2d<float, access::read> chroma [[texture(1)]],
                                   constant float4 &coeff     [[buffer(0)]],
                                   constant float4 &levels    [[buffer(1)]],
                                   constant float  &codeScale [[buffer(2)]]) {
        uint2 gid = uint2(in.position.xy);
        gid = min(gid, uint2(luma.get_width() - 1, luma.get_height() - 1));
        uint2 cid = min(gid / 2, uint2(chroma.get_width() - 1, chroma.get_height() - 1));

        float  Y    = luma.read(gid).r * codeScale;
        float2 CbCr = chroma.read(cid).rg * codeScale;

        float y = (Y - levels.x) / levels.y;
        float u = (CbCr.x - levels.z) / levels.w;
        float v = (CbCr.y - levels.z) / levels.w;

        float3 rgb = clamp(float3(y + coeff.x * v,
                                  y - coeff.y * u - coeff.z * v,
                                  y + coeff.w * u), 0.0, 1.0);
        if (applyDither) {
            float n = hash12(in.position.xy) - hash12(in.position.xy + 17.0);   // triangular in (-1, 1)
            rgb += n * (1.0 / 1023.0);                                          // ≤1 LSB at 10-bit
        }
        return float4(rgb, 1.0);
    }
    """
}
