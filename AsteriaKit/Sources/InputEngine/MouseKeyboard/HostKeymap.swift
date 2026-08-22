/// Translates key scancode to Win32 virtual-key code. Maps by scancode (USB-HID usage ID) so the host corrects for non-US layouts. Returns nil for unmapped keys or uncaptured system keys.
public enum HostKeymap {
    public static func map(scancode: Int, swapWinAlt: Bool,
                           systemKeyCaptureActive: Bool) -> (keyCode: Int16, nonNormalized: Bool)? {
        if scancode >= SC.n1 && scancode <= SC.n9 {
            return (Int16((scancode - SC.n1) + VK._0 + 1), false)
        }
        if scancode >= SC.a && scancode <= SC.z {
            return (Int16((scancode - SC.a) + VK.a), false)
        }
        if scancode >= SC.f1 && scancode <= SC.f12 {
            return (Int16((scancode - SC.f1) + VK.f1), false)
        }
        if scancode >= SC.f13 && scancode <= SC.f24 {
            return (Int16((scancode - SC.f13) + VK.f13), false)
        }
        if scancode >= SC.kp1 && scancode <= SC.kp9 {
            return (Int16((scancode - SC.kp1) + VK.numpad0 + 1), false)
        }

        switch scancode {
        case SC.backspace: return (0x08, false)
        case SC.tab: return (0x09, false)
        case SC.clear: return (0x0C, false)
        case SC.kpEnter, SC.return_: return (0x0D, false)
        case SC.pause: return (0x13, false)
        case SC.capsLock: return (0x14, false)
        case SC.escape: return (0x1B, false)
        case SC.space: return (0x20, false)
        case SC.pageUp: return (0x21, false)
        case SC.pageDown: return (0x22, false)
        case SC.end: return (0x23, false)
        case SC.home: return (0x24, false)
        case SC.left: return (0x25, false)
        case SC.up: return (0x26, false)
        case SC.right: return (0x27, false)
        case SC.down: return (0x28, false)
        case SC.select: return (0x29, false)
        case SC.execute: return (0x2B, false)
        case SC.printScreen: return (0x2C, false)
        case SC.insert: return (0x2D, false)
        case SC.delete: return (0x2E, false)
        case SC.help: return (0x2F, false)
        case SC.kp0: return (Int16(VK.numpad0), false)
        case SC.n0: return (Int16(VK._0), false)
        case SC.kpMultiply: return (0x6A, false)
        case SC.kpPlus: return (0x6B, false)
        case SC.kpComma: return (0x6C, false)
        case SC.kpMinus: return (0x6D, false)
        case SC.kpPeriod: return (0x6E, false)
        case SC.kpDivide: return (0x6F, false)
        case SC.numLockClear: return (0x90, false)
        case SC.scrollLock: return (0x91, false)
        case SC.lShift: return (Int16(0xA0), false)
        case SC.rShift: return (Int16(0xA1), false)
        case SC.lCtrl: return (Int16(0xA2), false)
        case SC.rCtrl: return (Int16(0xA3), false)
        case SC.lAlt: return (Int16(swapWinAlt ? VK.lWin : VK.lAlt), false)
        case SC.rAlt: return (Int16(swapWinAlt ? VK.rWin : VK.rAlt), false)
        case SC.lGui:
            if !systemKeyCaptureActive && !swapWinAlt { return nil }
            return (Int16(swapWinAlt ? VK.lAlt : VK.lWin), false)
        case SC.rGui:
            if !systemKeyCaptureActive && !swapWinAlt { return nil }
            return (Int16(swapWinAlt ? VK.rAlt : VK.rWin), false)
        case SC.application: return (0x5D, false)
        case SC.acBack: return (Int16(0xA6), false)
        case SC.acForward: return (Int16(0xA7), false)
        case SC.acRefresh: return (Int16(0xA8), false)
        case SC.acStop: return (Int16(0xA9), false)
        case SC.acSearch: return (Int16(0xAA), false)
        case SC.acBookmarks: return (Int16(0xAB), false)
        case SC.acHome: return (Int16(0xAC), false)
        case SC.semicolon: return (Int16(0xBA), false)
        case SC.equals: return (Int16(0xBB), false)
        case SC.comma: return (Int16(0xBC), false)
        case SC.minus: return (Int16(0xBD), false)
        case SC.period: return (Int16(0xBE), false)
        case SC.slash: return (Int16(0xBF), false)
        case SC.grave: return (Int16(0xC0), false)
        case SC.leftBracket: return (Int16(0xDB), false)
        case SC.international3, SC.backslash: return (Int16(0xDC), scancode == SC.international3)
        // Yen key shares BACKSLASH VK; mark non-normalized to avoid re-normalization.
        case SC.rightBracket: return (Int16(0xDD), false)
        case SC.apostrophe: return (Int16(0xDE), false)
        case SC.international1, SC.nonUsBackslash: return (Int16(0xE2), scancode == SC.international1)
        // Non-US backslash shares VK with INTERNATIONAL1; mark non-normalized.
        case SC.lang1: return (0x1C, false)
        case SC.lang2: return (0x1D, false)
        default: return nil
        }
    }

    private enum VK {
        static let _0 = 0x30, a = 0x41
        static let lAlt = 0xA4, rAlt = 0xA5, lWin = 0x5B, rWin = 0x5C
        static let f1 = 0x70, f13 = 0x7C, numpad0 = 0x60
    }

    private enum SC {
        static let a = 4, z = 29
        static let n1 = 30, n9 = 38, n0 = 39
        static let return_ = 40, escape = 41, backspace = 42, tab = 43, space = 44
        static let minus = 45, equals = 46, leftBracket = 47, rightBracket = 48, backslash = 49
        static let semicolon = 51, apostrophe = 52, grave = 53, comma = 54, period = 55, slash = 56
        static let capsLock = 57
        static let f1 = 58, f12 = 69
        static let printScreen = 70, scrollLock = 71, pause = 72, insert = 73
        static let home = 74, pageUp = 75, delete = 76, end = 77, pageDown = 78
        static let right = 79, left = 80, down = 81, up = 82
        static let numLockClear = 83, kpDivide = 84, kpMultiply = 85, kpMinus = 86, kpPlus = 87, kpEnter = 88
        static let kp1 = 89, kp9 = 97, kp0 = 98, kpPeriod = 99
        static let nonUsBackslash = 100, application = 101
        static let f13 = 104, f24 = 115
        static let execute = 116, help = 117, select = 119
        static let kpComma = 133
        static let international1 = 135, international3 = 137
        static let lang1 = 144, lang2 = 145
        static let clear = 156
        static let acSearch = 268, acHome = 269, acBack = 270, acForward = 271
        static let acStop = 272, acRefresh = 273, acBookmarks = 274
        static let lCtrl = 224, lShift = 225, lAlt = 226, lGui = 227
        static let rCtrl = 228, rShift = 229, rAlt = 230, rGui = 231
    }
}
