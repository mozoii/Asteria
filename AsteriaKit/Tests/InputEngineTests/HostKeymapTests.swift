import Testing
@testable import InputEngine

@Suite("Host keymap (scancode → VK)")
struct HostKeymapTests {
    private func vk(_ scancode: Int) -> Int16? {
        guard let r = HostKeymap.map(scancode: scancode, swapWinAlt: false, systemKeyCaptureActive: false)
        else { return nil }
        #expect(r.nonNormalized == false)
        return r.keyCode
    }

    @Test(arguments: [
        (4, Int16(0x41)),    // A
        (29, Int16(0x5A)),   // Z
        (30, Int16(0x31)),   // '1'
        (38, Int16(0x39)),   // '9'
        (39, Int16(0x30)),   // '0' (handled out of the 1-9 range)
        (58, Int16(0x70)),   // F1
        (69, Int16(0x7B)),   // F12
        (104, Int16(0x7C)),  // F13
        (115, Int16(0x87)),  // F24
        (89, Int16(0x61)),   // KP_1
        (97, Int16(0x69)),   // KP_9
        (98, Int16(0x60)),   // KP_0 (handled out of the KP_1-9 range)
    ])
    func arithmeticRanges(scancode: Int, expected: Int16) {
        #expect(vk(scancode) == expected)
    }

    @Test(arguments: [(Int, Int16)]([
        (40, Int16(0x0D)),   // RETURN
        (88, Int16(0x0D)),   // KP_ENTER (shares RETURN)
        (41, Int16(0x1B)),   // ESCAPE
        (44, Int16(0x20)),   // SPACE
        (42, Int16(0x08)),   // BACKSPACE
        (43, Int16(0x09)),   // TAB
        (156, Int16(0x0C)),  // CLEAR
        (80, Int16(0x25)),   // LEFT
        (82, Int16(0x26)),   // UP
        (79, Int16(0x27)),   // RIGHT
        (81, Int16(0x28)),   // DOWN
        (225, Int16(0xA0)),  // LSHIFT
        (229, Int16(0xA1)),  // RSHIFT
        (224, Int16(0xA2)),  // LCTRL
        (228, Int16(0xA3)),  // RCTRL
        (53, Int16(0xC0)),   // GRAVE
        (51, Int16(0xBA)),   // SEMICOLON
        (144, Int16(0x1C)),  // LANG1
        (145, Int16(0x1D)),  // LANG2
        (101, Int16(0x5D)),  // APPLICATION
    ]))
    func switchCases(scancode: Int, expected: Int16) {
        #expect(vk(scancode) == expected)
    }

    @Test func altMapsToVkAltOrWinUnderSwap() {
        // LALT(226): VK_LALT normally, VK_LWIN when swapped. RALT(230): VK_RALT / VK_RWIN.
        #expect(HostKeymap.map(scancode: 226, swapWinAlt: false, systemKeyCaptureActive: false)?.keyCode == 0xA4)
        #expect(HostKeymap.map(scancode: 226, swapWinAlt: true, systemKeyCaptureActive: false)?.keyCode == 0x5B)
        #expect(HostKeymap.map(scancode: 230, swapWinAlt: false, systemKeyCaptureActive: false)?.keyCode == 0xA5)
        #expect(HostKeymap.map(scancode: 230, swapWinAlt: true, systemKeyCaptureActive: false)?.keyCode == 0x5C)
    }

    @Test func guiKeysGatedByCaptureAndSwap() {
        // LGUI(227)/RGUI(231) are dropped unless capturing system keys or Win↔Alt is swapped.
        #expect(HostKeymap.map(scancode: 227, swapWinAlt: false, systemKeyCaptureActive: false) == nil)
        #expect(HostKeymap.map(scancode: 231, swapWinAlt: false, systemKeyCaptureActive: false) == nil)
        // Capturing: LGUI→VK_LWIN, RGUI→VK_RWIN.
        #expect(HostKeymap.map(scancode: 227, swapWinAlt: false, systemKeyCaptureActive: true)?.keyCode == 0x5B)
        #expect(HostKeymap.map(scancode: 231, swapWinAlt: false, systemKeyCaptureActive: true)?.keyCode == 0x5C)
        // Swapped (no capture): LGUI→VK_LALT, RGUI→VK_RALT.
        #expect(HostKeymap.map(scancode: 227, swapWinAlt: true, systemKeyCaptureActive: false)?.keyCode == 0xA4)
        #expect(HostKeymap.map(scancode: 231, swapWinAlt: true, systemKeyCaptureActive: false)?.keyCode == 0xA5)
    }

    @Test func internationalKeysAreNonNormalized() {
        // INTERNATIONAL3 shares BACKSLASH's VK (0xDC) but must not be re-normalized; BACKSLASH is normal.
        let i3 = HostKeymap.map(scancode: 137, swapWinAlt: false, systemKeyCaptureActive: false)
        #expect(i3?.keyCode == 0xDC); #expect(i3?.nonNormalized == true)
        let bs = HostKeymap.map(scancode: 49, swapWinAlt: false, systemKeyCaptureActive: false)
        #expect(bs?.keyCode == 0xDC); #expect(bs?.nonNormalized == false)
        // INTERNATIONAL1 shares NONUSBACKSLASH's VK (0xE2); only INTERNATIONAL1 is non-normalized.
        let i1 = HostKeymap.map(scancode: 135, swapWinAlt: false, systemKeyCaptureActive: false)
        #expect(i1?.keyCode == 0xE2); #expect(i1?.nonNormalized == true)
        let nub = HostKeymap.map(scancode: 100, swapWinAlt: false, systemKeyCaptureActive: false)
        #expect(nub?.keyCode == 0xE2); #expect(nub?.nonNormalized == false)
    }

    @Test func unmappedScancodesReturnNil() {
        #expect(HostKeymap.map(scancode: 3, swapWinAlt: false, systemKeyCaptureActive: false) == nil)
        #expect(HostKeymap.map(scancode: 250, swapWinAlt: false, systemKeyCaptureActive: false) == nil)
        #expect(HostKeymap.map(scancode: 0, swapWinAlt: false, systemKeyCaptureActive: false) == nil)
    }
}
