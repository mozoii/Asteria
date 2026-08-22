import Testing
@testable import AsteriaModel

@Suite("ClipboardSyncModel — change detection")
struct ClipboardSyncTests {
    @Test("first poll pushes the current clipboard so enabling syncs immediately")
    func firstPollPushes() {
        var model = ClipboardSyncModel()
        #expect(model.textToSync(changeCount: 7, text: "hello") == "hello")
    }

    @Test("an unchanged change-count is not re-sent")
    func unchangedIsSkipped() {
        var model = ClipboardSyncModel()
        _ = model.textToSync(changeCount: 7, text: "hello")
        #expect(model.textToSync(changeCount: 7, text: "hello") == nil)
    }

    @Test("a new change-count pushes the new text")
    func changedIsSent() {
        var model = ClipboardSyncModel()
        _ = model.textToSync(changeCount: 7, text: "hello")
        #expect(model.textToSync(changeCount: 8, text: "world") == "world")
    }

    @Test("non-text/empty clipboards are consumed silently, not pushed")
    func emptyIsConsumedNotSent() {
        var model = ClipboardSyncModel()
        #expect(model.textToSync(changeCount: 3, text: nil) == nil)
        #expect(model.textToSync(changeCount: 3, text: "") == nil)
        // The change-count was recorded, so later text at the same count is still skipped.
        #expect(model.textToSync(changeCount: 3, text: "late") == nil)
        // ...but a genuinely new change is pushed.
        #expect(model.textToSync(changeCount: 4, text: "next") == "next")
    }
}
