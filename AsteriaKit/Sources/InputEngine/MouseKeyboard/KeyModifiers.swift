import GameStreamProtocol

/// Per-side keyboard modifier state tracked from ordered event stream (not polling). Bit values match SDL's `KMOD_*` for exact scancode mapping.
public struct KeyModifiers: OptionSet, Sendable, Equatable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    public static let lShift = KeyModifiers(rawValue: 0x0001)
    public static let rShift = KeyModifiers(rawValue: 0x0002)
    public static let lCtrl  = KeyModifiers(rawValue: 0x0040)
    public static let rCtrl  = KeyModifiers(rawValue: 0x0080)
    public static let lAlt   = KeyModifiers(rawValue: 0x0100)
    public static let rAlt   = KeyModifiers(rawValue: 0x0200)
    public static let lGui   = KeyModifiers(rawValue: 0x0400)
    public static let rGui   = KeyModifiers(rawValue: 0x0800)

    public static let ctrl:  KeyModifiers = [.lCtrl, .rCtrl]
    public static let shift: KeyModifiers = [.lShift, .rShift]
    public static let alt:   KeyModifiers = [.lAlt, .rAlt]
    public static let gui:   KeyModifiers = [.lGui, .rGui]

    public static func bit(forScancode scancode: Int) -> KeyModifiers {
        switch scancode {
        case 224: return .lCtrl
        case 225: return .lShift
        case 226: return .lAlt
        case 227: return .lGui
        case 228: return .rCtrl
        case 229: return .rShift
        case 230: return .rAlt
        case 231: return .rGui
        default:  return []
        }
    }

    public mutating func update(scancode: Int, pressed: Bool) {
        let b = Self.bit(forScancode: scancode)
        if pressed { formUnion(b) } else { subtract(b) }
    }

    public var classes: ModifierClass {
        var c: ModifierClass = []
        if !isDisjoint(with: .ctrl)  { c.insert(.ctrl) }
        if !isDisjoint(with: .shift) { c.insert(.shift) }
        if !isDisjoint(with: .alt)   { c.insert(.alt) }
        if !isDisjoint(with: .gui)   { c.insert(.gui) }
        return c
    }

    public func hostModifierByte(swapWinAlt: Bool, systemKeyCaptureActive: Bool) -> UInt8 {
        var m: UInt8 = 0
        let c = classes
        if c.contains(.ctrl)  { m |= InputEncoder.modifierCtrl }
        if c.contains(.alt)   { m |= InputEncoder.modifierAlt }
        if c.contains(.shift) { m |= InputEncoder.modifierShift }
        if c.contains(.gui) && systemKeyCaptureActive { m |= InputEncoder.modifierMeta }
        if swapWinAlt {
            let hadAlt = m & InputEncoder.modifierAlt != 0
            let hadMeta = m & InputEncoder.modifierMeta != 0
            m &= ~(InputEncoder.modifierAlt | InputEncoder.modifierMeta)
            if hadAlt  { m |= InputEncoder.modifierMeta }
            if hadMeta { m |= InputEncoder.modifierAlt }
        }
        return m
    }
}

/// Combined (side-agnostic) modifier classes for combo matching.
public struct ModifierClass: OptionSet, Sendable, Equatable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let ctrl  = ModifierClass(rawValue: 0x01)
    public static let shift = ModifierClass(rawValue: 0x02)
    public static let alt   = ModifierClass(rawValue: 0x04)
    public static let gui   = ModifierClass(rawValue: 0x08)
    public static let ctrlAltShift: ModifierClass = [.ctrl, .alt, .shift]
}
