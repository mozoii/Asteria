import Testing
@testable import InputEngine

@Suite("AbsoluteMouse mapping")
struct AbsoluteMouseTests {
    @Test func exactFitIsOneToOne() {
        let rect = AbsoluteMouse.videoRect(streamWidth: 1920, streamHeight: 1080,
                                           viewWidth: 1920, viewHeight: 1080)
        #expect(rect.x == 0 && rect.y == 0 && rect.w == 1920 && rect.h == 1080)
    }

    @Test func letterboxesVerticallyWhenViewIsTallerThanAspect() {
        // 1920×1080 into a 1000×1000 view → 1000×563 centred vertically.
        let rect = AbsoluteMouse.videoRect(streamWidth: 1920, streamHeight: 1080,
                                           viewWidth: 1000, viewHeight: 1000)
        #expect(rect.x == 0 && rect.w == 1000)
        #expect(rect.h == 563)
        #expect(rect.y == (1000 - 563) / 2)   // 218
    }

    @Test func pillarboxesWhenViewIsWiderThanAspect() {
        // 1920×1080 into a 1920×400 view → 712×400 centred horizontally.
        let rect = AbsoluteMouse.videoRect(streamWidth: 1920, streamHeight: 1080,
                                           viewWidth: 1920, viewHeight: 400)
        #expect(rect.y == 0 && rect.h == 400)
        #expect(rect.w == 712)
        #expect(rect.x == (1920 - 712) / 2)   // 604
    }

    @Test func mapClampsToVideoRectAndReportsReferenceDims() {
        // Vertical letterbox: a point inside maps relative to the rect origin.
        let m = AbsoluteMouse.map(pointX: 500, pointY: 500, streamWidth: 1920, streamHeight: 1080,
                                  viewWidth: 1000, viewHeight: 1000)
        #expect(m?.x == 500)
        #expect(m?.y == 282)              // 500 − 218
        #expect(m?.refW == 1000)
        #expect(m?.refH == 563)
    }

    @Test func mapClampsPointsOutsideTheVideoRect() {
        // A point above the letterbox clamps to the top edge (y = 0).
        let m = AbsoluteMouse.map(pointX: 500, pointY: 10, streamWidth: 1920, streamHeight: 1080,
                                  viewWidth: 1000, viewHeight: 1000)
        #expect(m?.y == 0)
    }

    @Test func mapKeepsCoordinatesWithinTheReferenceRange() {
        let m = AbsoluteMouse.map(pointX: 1000, pointY: 1000, streamWidth: 100, streamHeight: 100,
                                  viewWidth: 1000, viewHeight: 1000)
        #expect(m?.x == 999)
        #expect(m?.y == 999)
        #expect(m?.refW == 1000)
        #expect(m?.refH == 1000)
    }

    @Test func mapClampsAllLetterboxEdgesToVisibleVideoPixels() {
        let topLeft = AbsoluteMouse.map(pointX: -1, pointY: 0, streamWidth: 1920,
                                        streamHeight: 1080,
                                        viewWidth: 1000, viewHeight: 1000)
        let bottomRight = AbsoluteMouse.map(pointX: 1000, pointY: 1000, streamWidth: 1920,
                                            streamHeight: 1080, viewWidth: 1000, viewHeight: 1000)

        #expect(topLeft?.x == 0)
        #expect(topLeft?.y == 0)
        #expect(bottomRight?.x == 999)
        #expect(bottomRight?.y == 562)
    }
}
