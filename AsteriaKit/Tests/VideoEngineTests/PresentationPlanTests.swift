import Testing
import CoreGraphics
@testable import VideoEngine

/// Presentation geometry for on-screen Metal: aspect-fit scaling, upscale decisions, and zero-size guard.
@Suite("Presentation plan")
struct PresentationPlanTests {
    private func plan(frame: (Int, Int), bounds: (CGFloat, CGFloat), scale: CGFloat) -> PresentationPlan {
        PresentationPlan(frameWidth: frame.0, frameHeight: frame.1,
                         boundsWidth: bounds.0, boundsHeight: bounds.1, contentsScale: scale)
    }

    @Test("a zero-bounds layer (not laid out yet) presents at native size — never a zero drawable")
    func zeroBoundsFallsBackToNative() {
        let p = plan(frame: (1920, 1080), bounds: (0, 0), scale: 2)
        #expect(p.targetWidth == 1920)
        #expect(p.targetHeight == 1080)
        #expect(!p.upscaleBeneficial)
    }

    @Test("a native-sized surface presents directly (no upscale)")
    func nativeIsDirect() {
        let p = plan(frame: (1920, 1080), bounds: (1920, 1080), scale: 1)
        #expect(p.targetWidth == 1920)
        #expect(p.targetHeight == 1080)
        #expect(!p.upscaleBeneficial)
    }

    @Test("a larger-than-target frame is not upscaled (compositor downscales)")
    func downscaleIsDirect() {
        let p = plan(frame: (3840, 2160), bounds: (1920, 1080), scale: 1)
        #expect(p.targetWidth == 3840)
        #expect(p.targetHeight == 2160)
        #expect(!p.upscaleBeneficial)
    }

    @Test("a sub-native frame upscales to the backing-pixel target")
    func subNativeUpscales() {
        let p = plan(frame: (1280, 720), bounds: (1920, 1080), scale: 1)
        #expect(p.targetWidth == 1920)
        #expect(p.targetHeight == 1080)
        #expect(p.upscaleBeneficial)
    }

    @Test("contentsScale is applied to bounds (Retina backing pixels)")
    func appliesContentsScale() {
        let p = plan(frame: (960, 540), bounds: (960, 540), scale: 2)
        #expect(p.targetWidth == 1920)
        #expect(p.targetHeight == 1080)
        #expect(p.upscaleBeneficial)
    }

    @Test("a mismatched aspect ratio fits to the limiting dimension (letterbox)")
    func aspectFitPicksLimitingDimension() {
        let p = plan(frame: (800, 600), bounds: (1920, 1080), scale: 1)
        // 4:3 frame into 16:9 box, height-limited.
        #expect(p.targetWidth == 1440)
        #expect(p.targetHeight == 1080)
        #expect(p.upscaleBeneficial)
    }

    @Test("only one dimension below target still upscales")
    func oneDimensionUpscales() {
        let direct = plan(frame: (1280, 1080), bounds: (1920, 1080), scale: 1)
        #expect(!direct.upscaleBeneficial)
        // Taller box enables upscaling.
        let up = plan(frame: (1280, 1080), bounds: (1920, 1620), scale: 1)
        #expect(up.upscaleBeneficial)
        #expect(up.targetWidth == 1920)
        #expect(up.targetHeight == 1620)
    }
}
