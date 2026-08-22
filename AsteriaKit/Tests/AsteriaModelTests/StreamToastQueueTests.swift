import Testing
@testable import AsteriaModel

@Suite("In-stream toast queue")
struct StreamToastQueueTests {
    @Test func presentsMessagesInFifoOrder() {
        var queue = StreamToastQueue()
        let first = StreamToast(category: .adaptiveBitrate, message: "First")
        let second = StreamToast(category: .adaptiveBitrate, message: "Second")

        let acceptedFirst = queue.enqueue(first)
        let acceptedSecond = queue.enqueue(second)
        #expect(acceptedFirst)
        #expect(acceptedSecond)
        #expect(queue.current == first)
        let next = queue.dismissCurrent()
        #expect(next == second)
        #expect(queue.current == second)
    }

    @Test func ignoresDuplicateVisibleOrQueuedMessages() {
        var queue = StreamToastQueue()
        let toast = StreamToast(category: .adaptiveBitrate, message: "Repeated")

        let acceptedFirst = queue.enqueue(toast)
        let acceptedDuplicate = queue.enqueue(toast)
        #expect(acceptedFirst)
        #expect(acceptedDuplicate == false)
        #expect(queue.count == 1)
    }

    @Test func clearRemovesVisibleAndQueuedMessages() {
        var queue = StreamToastQueue()
        _ = queue.enqueue(.init(category: .adaptiveBitrate, message: "First"))
        _ = queue.enqueue(.init(category: .adaptiveBitrate, message: "Second"))

        queue.clear()

        #expect(queue.current == nil)
        #expect(queue.count == 0)
    }

    @Test func policyRequiresSystemAndCategoryPermission() {
        let allowed = StreamNotificationPolicy(
            systemAllowed: true, adaptiveBitrateAllowed: true, muteAllowed: true)
        let systemDenied = StreamNotificationPolicy(
            systemAllowed: false, adaptiveBitrateAllowed: true, muteAllowed: true)
        let categoryDenied = StreamNotificationPolicy(
            systemAllowed: true, adaptiveBitrateAllowed: false, muteAllowed: true)

        #expect(allowed.allows(.adaptiveBitrate))
        #expect(systemDenied.allows(.adaptiveBitrate) == false)
        #expect(categoryDenied.allows(.adaptiveBitrate) == false)
    }

    @Test("Mute toasts follow the mute preference; system permission and ABR preference don't gate them")
    func muteToastsFollowMutePreference() {
        let muteAllowed = StreamNotificationPolicy(
            systemAllowed: false, adaptiveBitrateAllowed: false, muteAllowed: true)
        let muteDisallowed = StreamNotificationPolicy(
            systemAllowed: true, adaptiveBitrateAllowed: true, muteAllowed: false)

        #expect(muteAllowed.allows(.audioMuted))
        #expect(muteAllowed.allows(.audioUnmuted))
        #expect(muteDisallowed.allows(.audioMuted) == false)
        #expect(muteDisallowed.allows(.audioUnmuted) == false)
    }

    @Test("Muting and unmuting enqueue separately")
    func muteAndUnmuteDistinctToasts() {
        var queue = StreamToastQueue()
        _ = queue.enqueue(StreamToast(category: .audioMuted, message: "Audio muted"))
        _ = queue.enqueue(StreamToast(category: .audioUnmuted, message: "Audio unmuted"))
        #expect(queue.count == 2)
    }
}
