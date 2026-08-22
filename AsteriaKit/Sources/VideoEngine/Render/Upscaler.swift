import Metal
import MetalFX

/// Pluggable spatial-upscaling stage; MetalFX is one implementation.
public protocol Upscaler: AnyObject {
    var outputWidth: Int { get }
    var outputHeight: Int { get }
    /// Scale `input` into `output` (already sized to `outputWidth × outputHeight`) within `commandBuffer`.
    func encode(input: MTLTexture, output: MTLTexture, in commandBuffer: MTLCommandBuffer)
}

/// MetalFX spatial upscaler; colour mode `perceptual` for gamma-encoded SDR RGB.
public final class SpatialUpscaler: Upscaler {
    public let outputWidth: Int
    public let outputHeight: Int
    private let scaler: MTLFXSpatialScaler

    /// Whether MetalFX spatial scaling is available on this device.
    public static func isSupported(device: MTLDevice) -> Bool {
        MTLFXSpatialScalerDescriptor.supportsDevice(device)
    }

    public init(context: MetalRenderContext, inputWidth: Int, inputHeight: Int,
                outputWidth: Int, outputHeight: Int, colorFormat: MTLPixelFormat = .rgba16Float) throws {
        let descriptor = MTLFXSpatialScalerDescriptor()
        descriptor.inputWidth = inputWidth
        descriptor.inputHeight = inputHeight
        descriptor.outputWidth = outputWidth
        descriptor.outputHeight = outputHeight
        descriptor.colorTextureFormat = colorFormat
        descriptor.outputTextureFormat = colorFormat
        descriptor.colorProcessingMode = .perceptual
        guard let scaler = descriptor.makeSpatialScaler(device: context.device) else {
            throw MetalRenderError.pipeline("MTLFXSpatialScaler creation failed (unsupported configuration)")
        }
        self.scaler = scaler
        self.outputWidth = outputWidth
        self.outputHeight = outputHeight
    }

    public func encode(input: MTLTexture, output: MTLTexture, in commandBuffer: MTLCommandBuffer) {
        scaler.colorTexture = input
        scaler.outputTexture = output
        scaler.encode(commandBuffer: commandBuffer)
    }
}
