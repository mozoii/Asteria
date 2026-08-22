import Testing
import AsteriaModel

@Suite("Settings deck navigator")
struct SettingsDeckNavigatorTests {
    /// Video section: full chrome, two populated columns, not inheriting.
    private let video = DeckLayout(
        chrome: [.back, .scope(false), .scope(true)], sectionId: "video",
        left: ["Display mode", "Resolution", "Frame rate", "Use V-Sync", "Use MetalFX"],
        right: ["Bitrate", "Codec", "Bit depth"], inheriting: false)

    /// Audio section: only a left column, no right column.
    private let audio = DeckLayout(
        chrome: [.back], sectionId: "audio",
        left: ["Channels", "Mute when inactive"], right: [], inheriting: false)

    @Test("focusFirst lands on the first left control")
    func focusFirstControls() {
        var nav = SettingsDeckNavigator()
        nav.focusFirst(video)
        #expect(nav.highlight == .control("Display mode"))
    }

    @Test("focusFirst lands on the scope switch when the host inherits globals")
    func focusFirstInheriting() {
        var nav = SettingsDeckNavigator()
        nav.focusFirst(DeckLayout(chrome: [.back, .scope(false), .scope(true)], sectionId: "video",
                                  left: video.left, right: video.right, inheriting: true))
        #expect(nav.highlight == .scope(false))
    }

    @Test("down through a column, clamped at the last row")
    func downClamps() {
        var nav = SettingsDeckNavigator()
        nav.focusFirst(video)                       // Display mode (row 0)
        for _ in 0 ..< 10 { nav.move(.down, video) }
        #expect(nav.highlight == .control("Use MetalFX"))   // last of 5, never past it
    }

    @Test("up from the top control row jumps to the tab row")
    func upToTabs() {
        var nav = SettingsDeckNavigator()
        nav.focusFirst(video)                       // row 0
        nav.move(.up, video)
        #expect(nav.highlight == .section("video"))
    }

    @Test("from tabs, up reaches chrome and down returns to controls")
    func tabsVertical() {
        var nav = SettingsDeckNavigator()
        nav.focusFirst(video)
        nav.move(.up, video)                        // tabs
        nav.move(.up, video)                        // chrome → Back
        #expect(nav.highlight == .back)
        nav.move(.down, video)                      // tabs
        nav.move(.down, video)                      // controls, row 0
        #expect(nav.highlight == .control("Display mode"))
    }

    @Test("right moves to the second column; empty column blocks the move")
    func horizontalColumns() {
        var nav = SettingsDeckNavigator()
        nav.focusFirst(video)
        #expect(nav.move(.right, video) == .stayed)
        #expect(nav.highlight == .control("Bitrate"))       // right column, row 0

        var mono = SettingsDeckNavigator()
        mono.focusFirst(audio)
        mono.move(.right, audio)                            // no right column → no move
        #expect(mono.highlight == .control("Channels"))
    }

    @Test("row index carries across a column switch, clamped to the shorter column")
    func rowClampsAcrossColumns() {
        var nav = SettingsDeckNavigator()
        nav.focusFirst(video)
        nav.move(.down, video); nav.move(.down, video); nav.move(.down, video)   // left row 3 (Use V-Sync)
        nav.move(.right, video)                             // right has only 3 rows → clamp to row 2
        #expect(nav.highlight == .control("Bit depth"))
    }

    @Test("left/right on the tab row and the shoulders ask the caller to switch section")
    func sectionSwitchSignals() {
        var nav = SettingsDeckNavigator()
        nav.focusFirst(video)
        nav.move(.up, video)                        // tabs
        #expect(nav.move(.right, video) == .switchSection(1))
        #expect(nav.move(.left, video) == .switchSection(-1))
        #expect(nav.move(.nextSection, video) == .switchSection(1))
        #expect(nav.move(.prevSection, video) == .switchSection(-1))
    }

    @Test("an empty active column falls through to the populated one")
    func emptyColumnFallsThrough() {
        var nav = SettingsDeckNavigator()
        nav.focusFirst(audio)                       // left column
        nav.move(.up, audio)                        // tabs
        nav.move(.down, audio)                      // controls: left non-empty → col 0
        #expect(nav.highlight == .control("Channels"))
    }

    @Test("dropdown selection opens on its current row and steps within bounds")
    func menuStepping() {
        var nav = SettingsDeckNavigator()
        nav.openMenu("Codec", index: 2)
        #expect(nav.openMenuLabel == "Codec")
        #expect(nav.menuIndex == 2)
        nav.stepMenu(1, itemCount: 3)               // clamp at last
        #expect(nav.menuIndex == 2)
        nav.stepMenu(-1, itemCount: 3)
        nav.stepMenu(-1, itemCount: 3)
        nav.stepMenu(-1, itemCount: 3)              // clamp at first
        #expect(nav.menuIndex == 0)
        nav.closeMenu()
        #expect(nav.openMenuLabel == nil)
    }
}
