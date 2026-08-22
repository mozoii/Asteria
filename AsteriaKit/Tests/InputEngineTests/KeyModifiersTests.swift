import Testing
import GameStreamProtocol
@testable import InputEngine

@Suite("KeyModifiers")
struct KeyModifiersTests {
    @Test func scancodeBitsArePerSide() {
        #expect(KeyModifiers.bit(forScancode: 224) == .lCtrl)
        #expect(KeyModifiers.bit(forScancode: 225) == .lShift)
        #expect(KeyModifiers.bit(forScancode: 226) == .lAlt)
        #expect(KeyModifiers.bit(forScancode: 227) == .lGui)
        #expect(KeyModifiers.bit(forScancode: 228) == .rCtrl)
        #expect(KeyModifiers.bit(forScancode: 229) == .rShift)
        #expect(KeyModifiers.bit(forScancode: 230) == .rAlt)
        #expect(KeyModifiers.bit(forScancode: 231) == .rGui)
        #expect(KeyModifiers.bit(forScancode: 4) == [])   // 'a' is not a modifier
    }

    @Test func updateTracksPressAndRelease() {
        var mods = KeyModifiers()
        mods.update(scancode: 224, pressed: true)   // LCtrl down
        mods.update(scancode: 230, pressed: true)   // RAlt down
        #expect(mods.contains(.lCtrl))
        #expect(mods.contains(.rAlt))
        #expect(mods.classes == [.ctrl, .alt])

        mods.update(scancode: 224, pressed: false)  // LCtrl up
        #expect(!mods.contains(.lCtrl))
        #expect(mods.classes == .alt)

        mods.update(scancode: 4, pressed: true)     // 'a' is a no-op
        #expect(mods.classes == .alt)
    }

    @Test func hostByteCollapsesSidesAndGatesMeta() {
        let cs: KeyModifiers = [.lCtrl, .rShift]
        #expect(cs.hostModifierByte(swapWinAlt: false, systemKeyCaptureActive: false)
                == InputEncoder.modifierCtrl | InputEncoder.modifierShift)

        #expect(KeyModifiers.lAlt.hostModifierByte(swapWinAlt: false, systemKeyCaptureActive: false)
                == InputEncoder.modifierAlt)

        // GUI is dropped unless system-key capture is active.
        #expect(KeyModifiers.lGui.hostModifierByte(swapWinAlt: false, systemKeyCaptureActive: false) == 0)
        #expect(KeyModifiers.lGui.hostModifierByte(swapWinAlt: false, systemKeyCaptureActive: true)
                == InputEncoder.modifierMeta)
    }

    @Test func swapWinAltExchangesAltAndMeta() {
        #expect(KeyModifiers.lAlt.hostModifierByte(swapWinAlt: true, systemKeyCaptureActive: true)
                == InputEncoder.modifierMeta)
        #expect(KeyModifiers.lGui.hostModifierByte(swapWinAlt: true, systemKeyCaptureActive: true)
                == InputEncoder.modifierAlt)
    }
}
