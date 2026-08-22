import Testing
@testable import AsteriaModel

@Suite("Deck cursor")
struct DeckCursorTests {
    private enum Item: Hashable { case chrome, host, app }

    private let deck: [[Item]] = [
        [.chrome],                      // row 0: single chrome item
        [.app, .app, .app],             // row 1: three apps
        [.host, .host],                 // row 2: two hosts (ragged)
    ]

    @Test("focusFirst lands on content, skipping the chrome row")
    func focusFirstSkipsChrome() {
        var cursor = DeckCursor<Item>()
        cursor.focusFirst(deck)
        #expect(cursor.highlight == .app)
    }

    @Test("focusFirst lands on chrome when there is no content")
    func focusFirstFallsBackToChrome() {
        var cursor = DeckCursor<Item>()
        cursor.focusFirst([[.chrome], []])
        #expect(cursor.highlight == .chrome)
    }

    @Test("empty layout clears the highlight")
    func emptyLayout() {
        var cursor = DeckCursor<Item>()
        cursor.focusFirst([[], []])
        #expect(cursor.highlight == nil)
        cursor.step(.right, rows: [[], []])
        #expect(cursor.highlight == nil)
    }

    @Test("moving up into a shorter row clamps the column")
    func raggedGridClampsColumn() {
        var cursor = DeckCursor<Item>()
        cursor.focusFirst(deck)                 // row 1, col 0
        cursor.step(.down, rows: deck)          // row 2, col 0
        cursor.step(.right, rows: deck)         // row 2, col 1
        cursor.step(.up, rows: deck)            // row 1 has 3 columns — col 1 stays
        #expect(cursor.highlight == .app)
        cursor.step(.down, rows: deck)
        cursor.step(.right, rows: deck)         // past row 2's width — clamped to col 1
        #expect(cursor.highlight == .host)
    }

    @Test("movement clamps to the layout bounds")
    func clampsAtEdges() {
        var cursor = DeckCursor<Item>()
        cursor.focusFirst(deck)
        cursor.step(.up, rows: deck)
        #expect(cursor.highlight == .chrome)    // row 0
        cursor.step(.left, rows: deck)
        #expect(cursor.highlight == .chrome)    // col stays 0
        cursor.step(.down, rows: deck)
        cursor.step(.down, rows: deck)
        cursor.step(.down, rows: deck)          // past the last row — stays
        #expect(cursor.highlight == .host)
    }

    @Test("syncHighlight re-renders against a changed layout")
    func syncAfterLayoutChange() {
        var cursor = DeckCursor<Item>()
        cursor.focusFirst(deck)
        cursor.syncHighlight([[.chrome], [.host]])   // row 1 replaced with a single item
        #expect(cursor.highlight == .host)
    }
}
