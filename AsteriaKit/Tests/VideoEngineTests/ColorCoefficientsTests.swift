import Testing
import CoreVideo
@testable import VideoEngine

@Suite("Colour-matrix coefficients")
struct ColorCoefficientsTests {
    @Test("BT.709 coefficients match the known matrix")
    func bt709() {
        let c = ColorCoefficients.bt709
        #expect(abs(c.crToR - 1.5748) < 0.001)
        #expect(abs(c.cbToB - 1.8556) < 0.001)
        #expect(abs(c.crToG - 0.4681) < 0.001)
        #expect(abs(c.cbToG - 0.1873) < 0.001)
    }

    @Test("BT.601 and BT.2020 differ from BT.709")
    func standardsDiffer() {
        #expect(abs(ColorCoefficients.bt601.crToR - 1.402) < 0.001)
        #expect(abs(ColorCoefficients.bt2020.crToR - 1.4746) < 0.001)
        #expect(ColorCoefficients.bt601 != ColorCoefficients.bt709)
        #expect(ColorCoefficients.bt2020 != ColorCoefficients.bt709)
    }

    @Test("forPixelBuffer reads the YCbCrMatrix tag; defaults to BT.709 when untagged")
    func readsTag() {
        let untagged = YUVToRGBRendererTests.makeNV12(width: 16, height: 16, y: 128, cb: 128, cr: 128)
        #expect(ColorCoefficients.forPixelBuffer(untagged) == .bt709)

        let tagged = YUVToRGBRendererTests.makeNV12(width: 16, height: 16, y: 128, cb: 128, cr: 128)
        CVBufferSetAttachment(tagged, kCVImageBufferYCbCrMatrixKey,
                              kCVImageBufferYCbCrMatrix_ITU_R_601_4, .shouldPropagate)
        #expect(ColorCoefficients.forPixelBuffer(tagged) == .bt601)
    }
}
