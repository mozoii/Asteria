import Metal

/// Fullscreen-triangle passthrough scaling CSC output to the present target. On the 10-bit path (`dither`) it adds a
/// static screen-space TPDF at ±1 LSB to break banding; the 8-bit path compiles it out (byte-for-byte passthrough).
public final class PresentRenderer {
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
        guard let vertex = library.makeFunction(name: "present_vertex") else {
            throw MetalRenderError.missingFunction("present_vertex")
        }
        let fragment: MTLFunction
        do {
            fragment = try library.makeFunction(name: "present_fragment", constantValues: constants)
        } catch {
            throw MetalRenderError.missingFunction("present_fragment")
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

    /// Encode the passthrough (+ optional dither) sampling `source` into `target`; caller presents/commits.
    public func encode(source: MTLTexture, into target: MTLTexture, in commandBuffer: MTLCommandBuffer) throws {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            throw MetalRenderError.encoder
        }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(source, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    constant bool applyDither [[function_constant(0)]];

    struct VOut { float4 position [[position]]; float2 uv; };

    vertex VOut present_vertex(uint vid [[vertex_id]]) {
        float2 pos[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
        VOut out;
        out.position = float4(pos[vid], 0.0, 1.0);
        out.uv = float2((pos[vid].x + 1.0) * 0.5, (1.0 - pos[vid].y) * 0.5);
        return out;
    }

    // Dave Hoskins hash: pixel coordinate → uniform [0,1). No time input, so the pattern is static (no shimmer).
    static inline float hash12(float2 p) {
        float3 p3 = fract(float3(p.xyx) * 0.1031);
        p3 += dot(p3, p3.yzx + 33.33);
        return fract((p3.x + p3.y) * p3.z);
    }

    fragment float4 present_fragment(VOut in [[stage_in]],
                                     texture2d<float> source [[texture(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float4 color = source.sample(s, in.uv);
        if (applyDither) {
            float n = hash12(in.position.xy) - hash12(in.position.xy + 17.0);   // triangular in (-1, 1)
            color.rgb += n * (1.0 / 1023.0);                                    // ≤1 LSB at 10-bit
        }
        return color;
    }
    """
}
