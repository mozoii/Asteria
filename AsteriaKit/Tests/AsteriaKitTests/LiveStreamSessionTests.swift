import Testing
@testable import AsteriaKit

@Suite("Live Stream Session")
struct LiveStreamSessionTests {
    @Test("unpaired Host Profile fails before creating stream transport")
    func rejectsUnpairedProfile() async {
        let profile = HostRecord(id: "office", name: "Office", address: "192.168.1.5")
        let plan = StreamConfigBuilder.plan(
            appId: "1",
            settings: .defaults,
            capabilities: .unrestricted
        )

        await #expect(throws: LiveStreamSessionFailure.self) {
            _ = try await LiveStreamSession.connect(
                profile: profile,
                identities: ClientIdentityVault(secretStore: InMemorySecretStore()),
                settings: .defaults,
                plan: plan,
                videoSink: EmptyVideoSink()
            )
        }
    }
}

private struct EmptyVideoSink: VideoSink {
    func makeRenderer(for videoFormat: VideoFormat) async -> DecoderRenderer? { nil }
}
