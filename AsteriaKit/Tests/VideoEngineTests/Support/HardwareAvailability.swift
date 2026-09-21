import Foundation
import Metal
import VideoToolbox
@testable import VideoEngine

/// Hardware the render and decode suites need. The iOS simulator has no hardware video decoder and no
/// MetalFX, so those suites are skipped there rather than failing: they assert real GPU behavior, and a
/// red run on a machine that cannot host the behavior says nothing about the code.
enum Hardware {
    static let hasMetalDevice: Bool = MTLCreateSystemDefaultDevice() != nil

    static let hasMetalFX: Bool = {
        guard let device = MTLCreateSystemDefaultDevice() else { return false }
        return SpatialUpscaler.isSupported(device: device)
    }()

    /// A present path also needs the runtime shader compile to succeed, which the simulator can fail
    /// independently of device creation.
    static let hasRenderPipeline: Bool = {
        guard hasMetalDevice, let context = try? MetalRenderContext() else { return false }
        return (try? YUVToRGBRenderer(context: context)) != nil
    }()

    static let hasHardwareHEVCDecode: Bool = VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)

    /// Any hardware video decoder at all. The simulator has none, which is what the codec probe
    /// smoke test is really asserting about the machine it runs on.
    static let hasHardwareDecoder: Bool =
        VTIsHardwareDecodeSupported(kCMVideoCodecType_H264) || hasHardwareHEVCDecode

    /// Whether this platform will build HDR10 tone-mapping metadata. The simulator returns nil for a
    /// well-formed pair of SEI attachments, so tests that assert adoption would fail there on
    /// environment rather than on behavior.
    static let hasEDRMetadata: Bool =
        MetalVideoPresenter.edrMetadata(masteringDisplay: Data(count: 24),
                                        contentLight: Data(count: 4)) != nil
}
