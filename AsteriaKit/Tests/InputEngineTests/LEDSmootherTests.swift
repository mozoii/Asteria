import Testing
@testable import InputEngine

@Suite("LED smoother")
struct LEDSmootherTests {
    @Test("a held color converges, then stops emitting writes")
    func steadyConverges() {
        var s = LEDSmoother()
        var last: (red: UInt8, green: UInt8, blue: UInt8)?
        for _ in 0..<200 { if let c = s.feed(red: 0, green: 0, blue: 255) { last = c } }
        #expect(last != nil)
        #expect(Int(last!.blue) > 220)   // converged near the held value

        var writes = 0
        for _ in 0..<50 where s.feed(red: 0, green: 0, blue: 255) != nil { writes += 1 }
        #expect(writes == 0)
    }

    @Test("a rapid full/off toggle settles, then the hysteresis absorbs the ripple with no writes")
    func pwmToggleSettles() {
        var s = LEDSmoother()
        for i in 0..<400 { _ = s.feed(red: 0, green: 0, blue: i.isMultiple(of: 2) ? 255 : 0) }

        var writes = 0
        for i in 0..<40 where s.feed(red: 0, green: 0, blue: i.isMultiple(of: 2) ? 255 : 0) != nil { writes += 1 }
        #expect(writes == 0)
    }

    @Test("a large color change emits a write")
    func largeChangeEmits() {
        var s = LEDSmoother()
        for _ in 0..<200 { _ = s.feed(red: 0, green: 0, blue: 255) }   // settle on blue
        var emitted = false
        for _ in 0..<200 where s.feed(red: 255, green: 0, blue: 0) != nil { emitted = true }
        #expect(emitted)
    }
}
