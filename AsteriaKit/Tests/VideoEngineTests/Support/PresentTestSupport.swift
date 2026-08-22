import CoreVideo
import Foundation
import Metal
@testable import VideoEngine

enum PresentTestError: Error { case pixelBufferCreate }

/// Offscreen Metal helpers for driving the present pipeline in tests: build source/target textures and read rows back.
enum PresentTestSupport {
    /// A 10-bit pixel buffer optionally carrying the HDR mastering-display + content-light SEI attachments,
    /// mirroring what VideoToolbox hangs off a decoded HDR frame.
    static func hdrPixelBuffer(width: Int, height: Int,
                               mastering: Data?, contentLight: Data?) throws -> CVPixelBuffer {
        var out: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                         kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, nil, &out)
        guard status == kCVReturnSuccess, let buffer = out else { throw PresentTestError.pixelBufferCreate }
        if let mastering {
            CVBufferSetAttachment(buffer, kCVImageBufferMasteringDisplayColorVolumeKey,
                                  mastering as CFData, .shouldPropagate)
        }
        if let contentLight {
            CVBufferSetAttachment(buffer, kCVImageBufferContentLightLevelInfoKey,
                                  contentLight as CFData, .shouldPropagate)
        }
        return buffer
    }

    static func shared(_ context: MetalRenderContext, pixelFormat: MTLPixelFormat,
                       width: Int, height: Int, usage: MTLTextureUsage) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat, width: width, height: height, mipmapped: false)
        descriptor.usage = usage
        descriptor.storageMode = .shared
        guard let texture = context.device.makeTexture(descriptor: descriptor) else {
            throw MetalRenderError.textureCreate
        }
        return texture
    }

    static func renderTarget(_ context: MetalRenderContext, pixelFormat: MTLPixelFormat,
                             width: Int, height: Int) throws -> MTLTexture {
        try shared(context, pixelFormat: pixelFormat, width: width, height: height,
                   usage: [.renderTarget, .shaderRead])
    }

    /// `rgba16Float` source filled per-pixel by `value(x, y)`.
    static func source(_ context: MetalRenderContext, width: Int, height: Int,
                       value: (Int, Int) -> SIMD4<Float>) throws -> MTLTexture {
        let texture = try shared(context, pixelFormat: .rgba16Float, width: width, height: height,
                                 usage: [.shaderRead])
        var data = [UInt16](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let v = value(x, y)
                let base = (y * width + x) * 4
                data[base + 0] = Float16(v.x).bitPattern
                data[base + 1] = Float16(v.y).bitPattern
                data[base + 2] = Float16(v.z).bitPattern
                data[base + 3] = Float16(v.w).bitPattern
            }
        }
        texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                        withBytes: &data, bytesPerRow: width * 4 * MemoryLayout<UInt16>.size)
        return texture
    }

    static func solid(_ context: MetalRenderContext, width: Int, height: Int,
                      rgba: SIMD4<Float>) throws -> MTLTexture {
        try source(context, width: width, height: height, value: { _, _ in rgba })
    }

    /// Read one row of a `bgra8Unorm` target as normalized R values.
    static func readRow8(_ texture: MTLTexture, y: Int) -> [Float] {
        let width = texture.width
        var bytes = [UInt8](repeating: 0, count: width * 4)
        texture.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, y, width, 1), mipmapLevel: 0)
        return (0..<width).map { Float(bytes[$0 * 4 + 2]) / 255.0 }   // bgra: R is byte 2
    }

    /// Read one row of a `bgr10a2Unorm` target as normalized R values.
    static func readRow10(_ texture: MTLTexture, y: Int) -> [Float] {
        let width = texture.width
        var words = [UInt32](repeating: 0, count: width)
        texture.getBytes(&words, bytesPerRow: width * 4, from: MTLRegionMake2D(0, y, width, 1), mipmapLevel: 0)
        return words.map { Float(($0 >> 20) & 0x3FF) / 1023.0 }        // bgr10a2: R is bits 20..29
    }
}
