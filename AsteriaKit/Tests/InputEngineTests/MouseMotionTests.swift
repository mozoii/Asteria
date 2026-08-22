import Testing
@testable import InputEngine

@Suite("Mouse motion / scroll / route")
struct MouseMotionTests {
    @Test func accumulatorCarriesSubPixelRemainder() {
        var acc = MouseMotionAccumulator()
        var r = acc.consume(deltaX: 0.6, deltaY: 0)
        #expect(r.dx == 0)
        r = acc.consume(deltaX: 0.6, deltaY: 0)
        #expect(r.dx == 1)
    }

    @Test func accumulatorPassesThroughY() {
        var acc = MouseMotionAccumulator()
        let r = acc.consume(deltaX: 0, deltaY: 3.0)
        #expect(r.dy == 3)
    }

    @Test func accumulatorTruncatesTowardZeroForNegatives() {
        var acc = MouseMotionAccumulator()
        var r = acc.consume(deltaX: -0.6, deltaY: 0)
        #expect(r.dx == 0)
        r = acc.consume(deltaX: -0.6, deltaY: 0)
        #expect(r.dx == -1)
    }

    @Test func resetDropsRemainder() {
        var acc = MouseMotionAccumulator()
        _ = acc.consume(deltaX: 0.9, deltaY: 0)
        acc.reset()
        let r = acc.consume(deltaX: 0.2, deltaY: 0)
        #expect(r.dx == 0)
    }

    @Test func scrollScalesClampsAndReverses() {
        #expect(MouseScroll.amount(precise: 0.5) == 60)
        #expect(MouseScroll.amount(precise: 2.0) == 120)
        #expect(MouseScroll.amount(precise: -2.0) == -120)
        #expect(MouseScroll.amount(precise: 0.5, reverse: true) == -60)
        #expect(MouseScroll.amount(precise: 0) == 0)
    }

    @Test func routeResolution() {
        #expect(MouseRoute.resolve(absoluteMode: true) == .absolute)
        #expect(MouseRoute.resolve(absoluteMode: false) == .relative)
    }

    @Test func appKitPointerOnlyForwardsInActiveDesktopMode() {
        #expect(MouseRoute.shouldForwardAppKitPointer(inputActive: true, absoluteMode: false) == false)
        #expect(MouseRoute.shouldForwardAppKitPointer(inputActive: true, absoluteMode: true) == true)
        #expect(MouseRoute.shouldForwardAppKitPointer(inputActive: false, absoluteMode: true) == false)
    }
}
