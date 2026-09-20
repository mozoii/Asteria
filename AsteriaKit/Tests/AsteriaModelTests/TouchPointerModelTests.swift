import Testing
@testable import AsteriaModel

/// The touch trackpad. On a phone with no mouse or keyboard these rules are the only way to click,
/// scroll, or reach the menu, so each classification is pinned here rather than left to the device.
@Suite("Touch pointer model")
struct TouchPointerModelTests {
    private func touch(_ id: Int, _ x: Double, _ y: Double) -> TouchPoint {
        TouchPoint(id: id, x: x, y: y)
    }

    @Test("a quick one-finger tap clicks the left button")
    func oneFingerTapLeftClicks() {
        var model = TouchPointerModel()

        #expect(model.update(touches: [touch(1, 100, 100)], at: 0).isEmpty)
        let released = model.update(touches: [], at: 0.1)

        #expect(released == [.leftButton(down: true), .leftButton(down: false)])
    }

    @Test("a quick two-finger tap clicks the right button")
    func twoFingerTapRightClicks() {
        var model = TouchPointerModel()

        _ = model.update(touches: [touch(1, 100, 100)], at: 0)
        _ = model.update(touches: [touch(1, 100, 100), touch(2, 140, 100)], at: 0.02)
        let released = model.update(touches: [], at: 0.15)

        #expect(released == [.rightButton(down: true), .rightButton(down: false)])
    }

    @Test("a three-finger tap opens the overlay menu")
    func threeFingerTapOpensMenu() {
        var model = TouchPointerModel()

        _ = model.update(touches: [touch(1, 100, 100)], at: 0)
        _ = model.update(touches: [touch(1, 100, 100), touch(2, 140, 100)], at: 0.02)
        _ = model.update(touches: [touch(1, 100, 100), touch(2, 140, 100), touch(3, 180, 100)], at: 0.04)
        let released = model.update(touches: [], at: 0.2)

        #expect(released == [.openMenu])
    }

    @Test("releasing one finger of a two-finger tap still right-clicks")
    func peakCountSurvivesStaggeredRelease() {
        var model = TouchPointerModel()

        _ = model.update(touches: [touch(1, 100, 100), touch(2, 140, 100)], at: 0)
        _ = model.update(touches: [touch(1, 100, 100)], at: 0.1)   // one lifts first
        let released = model.update(touches: [], at: 0.15)

        #expect(released == [.rightButton(down: true), .rightButton(down: false)])
    }

    @Test("a press held past the long-press window holds the left button down")
    func longPressHoldsLeftButton() {
        var model = TouchPointerModel()

        _ = model.update(touches: [touch(1, 100, 100)], at: 0)
        #expect(model.tick(at: 0.2).isEmpty)
        #expect(model.tick(at: 0.6) == [.leftButton(down: true)])
        // Already held: the button must not be pressed twice.
        #expect(model.tick(at: 0.9).isEmpty)

        #expect(model.update(touches: [], at: 1.2) == [.leftButton(down: false)])
    }

    @Test("a press that moved first never becomes a long press")
    func draggingSuppressesLongPress() {
        var model = TouchPointerModel()

        _ = model.update(touches: [touch(1, 100, 100)], at: 0)
        _ = model.update(touches: [touch(1, 160, 100)], at: 0.1)

        #expect(model.tick(at: 0.8).isEmpty)
        #expect(model.update(touches: [], at: 1.0).isEmpty)   // a drag doesn't click on release
    }

    @Test("a slow stationary press is not a tap")
    func slowPressIsNotATap() {
        var model = TouchPointerModel()

        _ = model.update(touches: [touch(1, 100, 100)], at: 0)
        // Released after the tap window but before anything ticked it into a hold.
        #expect(model.update(touches: [], at: 0.4).isEmpty)
    }

    @Test("one finger moving sends scaled relative motion in Game mode")
    func oneFingerDragMovesRelatively() {
        var model = TouchPointerModel(usesAbsolutePointer: false,
                                      tuning: .init(relativeScale: 2))

        _ = model.update(touches: [touch(1, 100, 100)], at: 0)
        let moved = model.update(touches: [touch(1, 110, 130)], at: 0.05)

        #expect(moved == [.moveRelative(dx: 20, dy: 60)])
    }

    @Test("one finger moving reports its position in Desktop mode")
    func oneFingerDragMovesAbsolutely() {
        var model = TouchPointerModel(usesAbsolutePointer: true)

        _ = model.update(touches: [touch(1, 100, 100)], at: 0)
        let moved = model.update(touches: [touch(1, 110, 130)], at: 0.05)

        #expect(moved == [.moveAbsolute(x: 110, y: 130)])
    }

    @Test("two fingers moving scroll instead of moving the pointer")
    func twoFingerDragScrolls() {
        var model = TouchPointerModel(tuning: .init(scrollScale: -1))

        _ = model.update(touches: [touch(1, 100, 100), touch(2, 140, 100)], at: 0)
        let moved = model.update(touches: [touch(1, 100, 120), touch(2, 140, 120)], at: 0.05)

        #expect(moved == [.scroll(dx: 0, dy: -20)])
    }

    @Test("adding a finger re-bases the centroid instead of flinging the pointer")
    func addingAFingerDoesNotJump() {
        var model = TouchPointerModel()

        _ = model.update(touches: [touch(1, 100, 100)], at: 0)
        // The second finger lands far away; the centroid jumps, but that is not motion.
        let joined = model.update(touches: [touch(1, 100, 100), touch(2, 300, 100)], at: 0.05)
        #expect(joined.isEmpty)

        let moved = model.update(touches: [touch(1, 110, 100), touch(2, 310, 100)], at: 0.1)
        #expect(moved == [.scroll(dx: -10, dy: 0)])
    }

    @Test("cancelling releases a held button and nothing else")
    func cancelReleasesHeldButton() {
        var model = TouchPointerModel()

        _ = model.update(touches: [touch(1, 100, 100)], at: 0)
        _ = model.tick(at: 0.6)

        #expect(model.cancel() == [.leftButton(down: false)])
        #expect(!model.isTracking)
    }

    @Test("cancelling an untouched model emits nothing")
    func cancelWithoutTouchesIsSilent() {
        var model = TouchPointerModel()
        #expect(model.cancel().isEmpty)
    }

    @Test("tracking follows whether any finger is down")
    func trackingReflectsTouchState() {
        var model = TouchPointerModel()
        #expect(!model.isTracking)

        _ = model.update(touches: [touch(1, 10, 10)], at: 0)
        #expect(model.isTracking)

        _ = model.update(touches: [], at: 0.1)
        #expect(!model.isTracking)
    }
}
