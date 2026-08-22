import Testing
@testable import AudioEngine

@Suite("CoreAudioRenderer")
struct CoreAudioRendererTests {
    @Test func safeBeforeStart() {
        let renderer = CoreAudioRenderer()
        #expect(renderer.renderStats() == AudioRenderStats())
        renderer.render([0, 0, 0, 0])
        #expect(renderer.renderStats() == AudioRenderStats())
    }

    @Test func stopBeforeStartIsSafe() {
        let renderer = CoreAudioRenderer()
        renderer.stop()
        #expect(renderer.renderStats() == AudioRenderStats())
    }

    @Test func clampsPreferredBufferIntoDeviceRange() {
        #expect(CoreAudioRenderer.clampedBufferFrames(target: 128, min: 64, max: 4096) == 128)
        #expect(CoreAudioRenderer.clampedBufferFrames(target: 128, min: 256, max: 4096) == 256)   // below device min
        #expect(CoreAudioRenderer.clampedBufferFrames(target: 128, min: 14, max: 64) == 64)       // above device max
        #expect(CoreAudioRenderer.clampedBufferFrames(target: 128, min: 512, max: 256) == 128)    // invalid range → target
    }

    @Test func reassertsOnlyWhenBufferGrewBeyondApplied() {
        #expect(CoreAudioRenderer.shouldReassertBuffer(current: 512, applied: 128))   // another client enlarged it
        #expect(!CoreAudioRenderer.shouldReassertBuffer(current: 128, applied: 128))  // unchanged
        #expect(!CoreAudioRenderer.shouldReassertBuffer(current: 144, applied: 144))  // device-coerced, stable → no loop
        #expect(!CoreAudioRenderer.shouldReassertBuffer(current: 64, applied: 128))   // smaller, leave it
        #expect(!CoreAudioRenderer.shouldReassertBuffer(current: 512, applied: 0))    // never applied yet
    }
}
