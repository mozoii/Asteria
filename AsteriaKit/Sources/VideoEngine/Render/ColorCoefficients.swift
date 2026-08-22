import CoreVideo
import simd

/// YCbCr→RGB matrix coefficients for CSC kernel: R = Y + crToR·Cr; B = Y + cbToB·Cb; G = Y − cbToG·Cb − crToG·Cr. Per-frame from `YCbCrMatrix` tag (BT.601/709/2020).
public struct ColorCoefficients: Equatable, Sendable {
    public let crToR: Float
    public let cbToG: Float
    public let crToG: Float
    public let cbToB: Float

    /// Packed for the kernel: (crToR, cbToG, crToG, cbToB).
    public var simd: SIMD4<Float> { SIMD4(crToR, cbToG, crToG, cbToB) }

    public static func from(kr: Float, kb: Float) -> ColorCoefficients {
        let kg = 1 - kr - kb
        return ColorCoefficients(crToR: 2 * (1 - kr),
                                 cbToG: 2 * (1 - kb) * kb / kg,
                                 crToG: 2 * (1 - kr) * kr / kg,
                                 cbToB: 2 * (1 - kb))
    }

    public static let bt709 = from(kr: 0.2126, kb: 0.0722)
    public static let bt601 = from(kr: 0.299, kb: 0.114)
    public static let bt2020 = from(kr: 0.2627, kb: 0.0593)

    /// Pick coefficients from a decoded buffer's `YCbCrMatrix` attachment; BT.709 if absent/unrecognized.
    public static func forPixelBuffer(_ pixelBuffer: CVPixelBuffer) -> ColorCoefficients {
        guard let value = CVBufferCopyAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey, nil),
              let matrix = value as? String else { return .bt709 }
        if matrix == kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String { return .bt601 }
        if matrix == kCVImageBufferYCbCrMatrix_ITU_R_2020 as String { return .bt2020 }
        return .bt709
    }
}
