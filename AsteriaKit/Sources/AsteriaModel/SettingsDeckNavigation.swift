/// The element the controller/keyboard highlight currently rests on in the settings deck.
public enum SettingsFocus: Hashable, Sendable {
    case back
    case section(String)
    case scope(Bool)
    case control(String)
}

/// A directional navigation input; activation, reset, and back are handled by the caller, not here.
public enum NavDir: Sendable {
    case up, down, left, right, prevSection, nextSection
}

/// Result of a move: either the cursor moved within the current section, or the caller should switch section
/// by the given delta (the caller owns `section`, then calls `syncHighlight` against the new layout).
public enum DeckMove: Equatable, Sendable {
    case stayed
    case switchSection(Int)
}

/// A snapshot of the deck's current layout the navigator reasons over: the chrome row, the two control
/// columns for the active section, the section id, and whether controls are inert (host inheriting globals).
public struct DeckLayout: Equatable, Sendable {
    public var chrome: [SettingsFocus]
    public var sectionId: String
    public var left: [String]
    public var right: [String]
    public var inheriting: Bool

    public init(chrome: [SettingsFocus], sectionId: String, left: [String], right: [String], inheriting: Bool) {
        self.chrome = chrome
        self.sectionId = sectionId
        self.left = left
        self.right = right
        self.inheriting = inheriting
    }
}

/// Pure 2D navigation for the settings deck: chrome, tabs, and two control columns; owns only the cursor
/// and the open-dropdown selection. Movement clamps to the live layout, so `highlight` is always valid.
public struct SettingsDeckNavigator: Sendable {
    enum Zone: Sendable { case chrome, tabs, controls }

    private var zone: Zone = .controls
    private var chromeCol = 0
    private var ctlCol = 0
    private var ctlRow = 0

    public private(set) var openMenuLabel: String?
    public private(set) var menuIndex = 0
    public private(set) var highlight: SettingsFocus?

    public init() {}

    private func controls(_ col: Int, _ layout: DeckLayout) -> [String] { col == 0 ? layout.left : layout.right }

    /// Recompute the rendered highlight from the current zone/indices, clamping to the live layout.
    public mutating func syncHighlight(_ layout: DeckLayout) {
        switch zone {
        case .chrome:
            let row = layout.chrome
            chromeCol = min(max(0, chromeCol), max(0, row.count - 1))
            highlight = row.isEmpty ? nil : row[chromeCol]
        case .tabs:
            highlight = .section(layout.sectionId)
        case .controls:
            var col = controls(ctlCol, layout)
            if col.isEmpty { ctlCol = ctlCol == 0 ? 1 : 0; col = controls(ctlCol, layout) }
            guard !col.isEmpty else { zone = .tabs; highlight = .section(layout.sectionId); return }
            ctlRow = min(max(0, ctlRow), col.count - 1)
            highlight = .control(col[ctlRow])
        }
    }

    /// Land the cursor from an empty state: scope switch when inheriting, else the first non-empty column, else tabs.
    public mutating func focusFirst(_ layout: DeckLayout) {
        if layout.inheriting {
            zone = .chrome
            chromeCol = layout.chrome.firstIndex { if case .scope = $0 { return true }; return false } ?? 0
        } else if !layout.left.isEmpty {
            zone = .controls; ctlCol = 0; ctlRow = 0
        } else if !layout.right.isEmpty {
            zone = .controls; ctlCol = 1; ctlRow = 0
        } else {
            zone = .tabs
        }
        syncHighlight(layout)
    }

    /// Apply a directional move; returns `.switchSection` when the caller must change section (tabs row or shoulders).
    @discardableResult
    public mutating func move(_ dir: NavDir, _ layout: DeckLayout) -> DeckMove {
        switch dir {
        case .up: moveVertical(-1, layout)
        case .down: moveVertical(1, layout)
        case .left: return moveHorizontal(-1, layout)
        case .right: return moveHorizontal(1, layout)
        case .prevSection: return .switchSection(-1)
        case .nextSection: return .switchSection(1)
        }
        return .stayed
    }

    private mutating func moveVertical(_ delta: Int, _ layout: DeckLayout) {
        switch zone {
        case .chrome:
            if delta > 0 { zone = .tabs }
        case .tabs:
            if delta < 0 { zone = .chrome; chromeCol = 0 }
            else { zone = .controls; ctlCol = controls(0, layout).isEmpty ? 1 : 0; ctlRow = 0 }
        case .controls:
            if delta < 0 && ctlRow == 0 { zone = .tabs } else { ctlRow += delta }
        }
        syncHighlight(layout)
    }

    private mutating func moveHorizontal(_ delta: Int, _ layout: DeckLayout) -> DeckMove {
        switch zone {
        case .chrome: chromeCol += delta; syncHighlight(layout)
        case .tabs: return .switchSection(delta)
        case .controls:
            let target = ctlCol + delta
            if (0...1).contains(target) && !controls(target, layout).isEmpty { ctlCol = target }
            syncHighlight(layout)
        }
        return .stayed
    }

    /// Open a dropdown for in-place navigation, starting on its currently-selected row.
    public mutating func openMenu(_ label: String, index: Int) {
        openMenuLabel = label
        menuIndex = index
    }

    public mutating func closeMenu() { openMenuLabel = nil }

    /// Step the open dropdown's selection, clamped to its item count.
    public mutating func stepMenu(_ delta: Int, itemCount: Int) {
        menuIndex = min(max(0, menuIndex + delta), max(0, itemCount - 1))
    }
}
