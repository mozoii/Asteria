import Testing
import Metal
@testable import VideoEngine

/// The 10-bit present path adds a static screen-space TPDF dither: deterministic, ≤1 LSB, and it demonstrably
/// shortens flat-region banding runs versus the 8-bit baseline.
@Suite("Present dither + banding")
struct DitherTests {
    /// Render a source through the present pass into a fresh target and return one row's normalized R values.
    static func present(_ context: MetalRenderContext, source: MTLTexture, pixelFormat: MTLPixelFormat,
                        dither: Bool, row: Int) throws -> [Float] {
        let renderer = try PresentRenderer(context: context, pixelFormat: pixelFormat, dither: dither)
        let target = try PresentTestSupport.renderTarget(context, pixelFormat: pixelFormat,
                                                         width: source.width, height: source.height)
        let commandBuffer = try #require(context.commandQueue.makeCommandBuffer())
        try renderer.encode(source: source, into: target, in: commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return pixelFormat == .bgr10a2Unorm ? PresentTestSupport.readRow10(target, y: row)
                                            : PresentTestSupport.readRow8(target, y: row)
    }

    /// Mean length of maximal runs of identical codes; longer runs = more visible banding.
    static func meanRunLength(_ codes: [Int]) -> Double {
        guard !codes.isEmpty else { return 0 }
        var runs = [Int]()
        var current = 1
        for i in 1..<codes.count {
            if codes[i] == codes[i - 1] { current += 1 } else { runs.append(current); current = 1 }
        }
        runs.append(current)
        return Double(runs.reduce(0, +)) / Double(runs.count)
    }

    @Test("the dither pattern is deterministic across renders (no temporal shimmer)")
    func deterministic() throws {
        let context = try MetalRenderContext()
        let source = try PresentTestSupport.solid(context, width: 64, height: 64, rgba: SIMD4<Float>(0.5, 0.5, 0.5, 1))
        let first = try Self.present(context, source: source, pixelFormat: .bgr10a2Unorm, dither: true, row: 20)
        let second = try Self.present(context, source: source, pixelFormat: .bgr10a2Unorm, dither: true, row: 20)
        #expect(first == second)
    }

    @Test("dither amplitude stays within ±1 LSB of the 10-bit code and varies")
    func amplitudeWithinOneLSB() throws {
        let context = try MetalRenderContext()
        let source = try PresentTestSupport.solid(context, width: 64, height: 64, rgba: SIMD4<Float>(0.5, 0.5, 0.5, 1))

        let undithered = try Self.present(context, source: source, pixelFormat: .bgr10a2Unorm, dither: false, row: 0)
        let base = Int((undithered[0] * 1023).rounded())

        let dithered = try Self.present(context, source: source, pixelFormat: .bgr10a2Unorm, dither: true, row: 30)
        let codes = dithered.map { Int(($0 * 1023).rounded()) }
        #expect(codes.allSatisfy { abs($0 - base) <= 1 })
        #expect(Set(codes).count >= 2)                       // dither actually spreads the flat region
    }

    @Test("10-bit + dither cuts flat-run length ≥4x versus the 8-bit baseline")
    func bandingImprovement() throws {
        let context = try MetalRenderContext()
        let width = 512, height = 8
        // Shallow horizontal ramp: spans only a few 8-bit codes, so the 8-bit target bands into long flat runs.
        let ramp = try PresentTestSupport.source(context, width: width, height: height) { x, _ in
            let v = 0.25 + (Float(x) / Float(width - 1)) * (6.0 / 255.0)
            return SIMD4<Float>(v, v, v, 1)
        }

        let row8 = try Self.present(context, source: ramp, pixelFormat: .bgra8Unorm, dither: false, row: 4)
        let row10 = try Self.present(context, source: ramp, pixelFormat: .bgr10a2Unorm, dither: true, row: 4)
        let run8 = Self.meanRunLength(row8.map { Int(($0 * 255).rounded()) })
        let run10 = Self.meanRunLength(row10.map { Int(($0 * 1023).rounded()) })

        #expect(run8 > 8)                 // absolute backstop: the 8-bit ramp really bands
        #expect(run10 < 4)                // absolute backstop: dithered 10-bit is near-continuous
        #expect(run8 / run10 >= 4)        // relative, self-calibrating
    }
}
