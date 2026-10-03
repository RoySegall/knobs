import CoreImage
import Foundation
import Testing
@testable import KnobsKit

@Suite("HighlightReconstructionPlugin")
struct HighlightReconstructionTests {
    static let size = 160
    /// Where the decoder clipped, as a linear value in every channel.
    static let clip: Float = 3.2
    /// The scene's color, warm like sunlit bark, at luminance 1.
    static let warm = SIMD3<Float>(1.15, 1.0, 0.85) / luma(SIMD3(1.15, 1.0, 0.85))
    /// Off-grid, so no two pixels around the peak are equal by symmetry.
    static let center = SIMD2<Float>(77.3, 81.6)

    static func luma(_ c: SIMD3<Float>) -> Float {
        0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z
    }

    static func apply(image: CIImage, source: RenderContext.Source = .raw, enabled: Bool = true) -> CIImage {
        let plugin = HighlightReconstructionPlugin()
        let values = KnobValues(params: plugin.params, stored: enabled ? [:] : ["enabled": .flag(false)])
        let context = RenderContext(scale: 1, fullSize: image.extent.size, source: source, analysis: PhotoAnalysis(clipLevel: clip))
        return plugin.apply(image: image, values: values, context: context)
    }

    /// Luminance of a smooth bright gradient with a bump whose peak is far above the clip level.
    static func scene(x: Int, y: Int, peak: Float) -> Float {
        let dx = Float(x) - center.x
        let dy = Float(y) - center.y
        return 0.4 + 1.2 * Float(x) / Float(size) + peak * exp(-(dx * dx + dy * dy) / (2 * 22 * 22))
    }

    /// The scene as the decoder writes it: a pixel with any channel past the clip level becomes the
    /// neutral clip white, so the bump's top is a flat disc with a hard rim.
    static func clippedDisc() -> CIImage {
        PresenceScene.make(width: size, height: size) { x, y in
            let color = warm * scene(x: x, y: y, peak: 8)
            return color.max() > clip ? SIMD3(repeating: clip) : color
        }
    }

    static func isClipWhite(_ c: SIMD3<Float>) -> Bool {
        abs(c.x - clip) < 1e-4 && abs(c.y - clip) < 1e-4 && abs(c.z - clip) < 1e-4
    }

    @Suite("identity")
    struct Identity {
        @Test("should leave a bitmap untouched")
        func bitmap() {
            let input = HighlightReconstructionTests.clippedDisc()
            let output = HighlightReconstructionTests.apply(image: input, source: .bitmap)
            #expect(Pixels.maxDifference(between: output, and: input) == 0)
        }

        @Test("should leave a RAW untouched when disabled")
        func disabled() {
            let input = HighlightReconstructionTests.clippedDisc()
            let output = HighlightReconstructionTests.apply(image: input, enabled: false)
            #expect(Pixels.maxDifference(between: output, and: input) == 0)
        }

        @Test("should leave a RAW with nothing clipped untouched")
        func nothingClipped() {
            let input = PresenceScene.make(width: HighlightReconstructionTests.size, height: HighlightReconstructionTests.size) { x, y in
                HighlightReconstructionTests.warm * HighlightReconstructionTests.scene(x: x, y: y, peak: 1.5)
            }
            let output = HighlightReconstructionTests.apply(image: input)
            #expect(Pixels.maxDifference(between: output, and: input) == 0)
        }

        @Test("should leave pixels finite", arguments: ["detail", "disc", "all clipped", "extremes"])
        func finite(name: String) {
            let size = HighlightReconstructionTests.size
            let input = switch name {
            case "detail": TestImages.detail()
            case "disc": HighlightReconstructionTests.clippedDisc()
            case "all clipped": TestImages.gray(level: HighlightReconstructionTests.clip, size: 64)
            default: PresenceScene.make(width: size, height: size) { x, y in
                (x / 8 + y / 8) % 3 == 0 ? SIMD3(repeating: 0) : (x / 8 + y / 8) % 3 == 1 ? SIMD3(1e4, -0.5, 1e-6) : SIMD3(repeating: 6)
            }
            }
            let output = HighlightReconstructionTests.apply(image: input)
            #expect(output.extent == input.extent)
            #expect(Pixels.read(output).allSatisfy { $0.isFinite })
        }
    }

    @Suite("fully clipped")
    struct FullyClipped {
        let input = HighlightReconstructionTests.clippedDisc()
        let before: PresencePixels
        let after: PresencePixels
        /// The middle row, which crosses the disc through its peak.
        let row: Int

        init() {
            before = PresencePixels(input)
            after = PresencePixels(HighlightReconstructionTests.apply(image: input))
            row = Int(HighlightReconstructionTests.center.y.rounded())
        }

        var discColumns: [Int] {
            (0..<HighlightReconstructionTests.size).filter { HighlightReconstructionTests.isClipWhite(before.rgb(x: $0, y: row)) }
        }

        func luminance(pixels: PresencePixels, x: Int) -> Float {
            HighlightReconstructionTests.luma(pixels.rgb(x: x, y: row))
        }

        @Test("should never darken a clipped pixel")
        func neverDarker() throws {
            let columns = discColumns
            try #require(columns.count > 20)
            for x in columns {
                #expect(luminance(pixels: after, x: x) >= luminance(pixels: before, x: x) - 1e-3)
            }
        }

        @Test("should fill the disc with a dome instead of a flat plateau")
        func dome() throws {
            let columns = discColumns
            try #require(columns.count > 20)
            let rim = max(luminance(pixels: after, x: columns.first!), luminance(pixels: after, x: columns.last!))
            let middle = luminance(pixels: after, x: Int(HighlightReconstructionTests.center.x.rounded()))
            #expect(middle > 1.3 * rim)
            #expect(middle > 1.3 * HighlightReconstructionTests.clip)
        }

        @Test("should meet the unclipped surroundings without a new hard edge")
        func seamless() throws {
            let columns = discColumns
            try #require(columns.count > 20)
            func largestStep(_ pixels: PresencePixels) -> Float {
                (1..<HighlightReconstructionTests.size).map { abs(luminance(pixels: pixels, x: $0) - luminance(pixels: pixels, x: $0 - 1)) }.max() ?? 0
            }
            #expect(largestStep(after) <= 1.25 * largestStep(before))
            // Outside the disc and its rim nothing moves.
            for x in 0..<(columns.first! - 8) {
                #expect(abs(luminance(pixels: after, x: x) - luminance(pixels: before, x: x)) < 1e-3)
            }
        }

        @Test("should color the rim like the surroundings and fade toward the clip white inside")
        func color() throws {
            let columns = discColumns
            try #require(columns.count > 20)
            let rim = after.rgb(x: columns.first! + 1, y: row)
            let middle = after.rgb(x: Int(HighlightReconstructionTests.center.x.rounded()), y: row)
            #expect(rim.x / rim.z > 1.1)
            #expect(middle.x / middle.z < rim.x / rim.z)
        }

        @Test("should keep the clipped area white after the display roll-off")
        func whiteAtDefaults() throws {
            let engine = RenderEngine(plugins: [])
            let shown = PresencePixels(engine.display(HighlightReconstructionTests.apply(image: input), source: .raw))
            for x in discColumns {
                #expect(shown.rgb(x: x, y: row).min() > 0.99)
            }
        }
    }

    @Suite("partly clipped")
    struct PartlyClipped {
        @Test("should bring a neutral patch with one clipped channel back to neutral")
        func neutralPatch() {
            let size = HighlightReconstructionTests.size
            let patchX = 100..<150
            let patchY = 50..<110
            let green: Float = 2
            // Neutral throughout; inside the patch green clipped at 2 while red and blue go on to 2.3.
            let input = PresenceScene.make(width: size, height: size) { x, y in
                guard patchX.contains(x), patchY.contains(y) else {
                    return SIMD3(repeating: 0.3 + 1.2 * Float(x) / Float(size))
                }
                let level = 2.05 + 0.25 * Float(x - patchX.lowerBound) / Float(patchX.count)
                return SIMD3(level, green, level)
            }
            let after = PresencePixels(HighlightReconstructionTests.apply(image: input))
            for y in stride(from: patchY.lowerBound + 3, to: patchY.upperBound - 3, by: 5) {
                for x in stride(from: patchX.lowerBound + 3, to: patchX.upperBound - 3, by: 5) {
                    let c = after.rgb(x: x, y: y)
                    #expect(c.y >= green - 1e-3)
                    #expect(abs(c.x - c.y) / c.y < 0.03, "x \(x) y \(y): \(c)")
                    #expect(abs(c.z - c.y) / c.y < 0.03, "x \(x) y \(y): \(c)")
                }
            }
        }
    }
}
