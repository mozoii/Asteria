import Testing
@testable import Pairing

@Suite("Dynamic PIN generation")
struct DynamicPinTests {
    @Test func pinIsFourDigits() {
        for _ in 0..<200 {
            let pin = PairingRandom.pin()
            #expect(pin.count == 4)
            #expect(pin.allSatisfy { $0.isNumber })
        }
    }

    @Test func pinIsNotConstant() {
        let pins = Set((0..<200).map { _ in PairingRandom.pin() })
        #expect(pins.count > 50)
    }

    @Test func pinDigitsCoverFullRange() {
        var seen = Set<Character>()
        for _ in 0..<500 {
            for ch in PairingRandom.pin() { seen.insert(ch) }
        }
        #expect(seen == Set("0123456789"))
    }
}
