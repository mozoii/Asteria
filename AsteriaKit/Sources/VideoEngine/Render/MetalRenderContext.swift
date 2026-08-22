import Metal
import CoreVideo

public enum MetalRenderError: Error, CustomStringConvertible {
    case noDevice
    case noCommandQueue
    case noTextureCache
    case libraryCompile(String)
    case missingFunction(String)
    case pipeline(String)
    case textureCreate
    case encoder

    public var description: String {
        switch self {
        case .noDevice: return "no Metal device (Apple Silicon GPU required)"
        case .noCommandQueue: return "could not create a Metal command queue"
        case .noTextureCache: return "could not create a CVMetalTextureCache"
        case .libraryCompile(let m): return "shader compile failed: \(m)"
        case .missingFunction(let n): return "shader function '\(n)' not found"
        case .pipeline(let m): return "pipeline state creation failed: \(m)"
        case .textureCreate: return "could not create/​wrap a Metal texture"
        case .encoder: return "could not create a command/compute encoder"
        }
    }
}

/// Shared Metal essentials: device, command queue, and `CVMetalTextureCache` for zero-copy pixel-buffer wrapping.
public final class MetalRenderContext {
    public let device: MTLDevice
    public let commandQueue: MTLCommandQueue
    let textureCache: CVMetalTextureCache

    public init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw MetalRenderError.noDevice }
        guard let queue = device.makeCommandQueue() else { throw MetalRenderError.noCommandQueue }
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess,
              let cache else { throw MetalRenderError.noTextureCache }
        self.device = device
        self.commandQueue = queue
        self.textureCache = cache
    }

    /// Zero-copy wrap pixel-buffer plane as Metal texture.
    func planeTexture(_ pixelBuffer: CVPixelBuffer, plane: Int,
                      format: MTLPixelFormat, width: Int, height: Int) throws -> MTLTexture {
        var cvTexture: CVMetalTexture?
        let result = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, pixelBuffer, nil,
            format, width, height, plane, &cvTexture)
        guard result == kCVReturnSuccess, let cvTexture,
              let texture = CVMetalTextureGetTexture(cvTexture) else { throw MetalRenderError.textureCreate }
        return texture
    }
}
