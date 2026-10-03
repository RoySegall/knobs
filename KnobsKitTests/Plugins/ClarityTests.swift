import CoreImage
import Foundation
import Testing
@testable import KnobsKit

@Suite("ClarityPlugin")
struct ClarityTests {
    static let width = 512
    static let height = 128
    /// The plugin's window radius on these scenes, in pixels.
    static let radius = ClarityPlugin.radius * Double(width)

    /// Large-scale ripples (a few windows across) around `base` on the left half and `rightBase` on the right.
    static func ripples(base: Float, rightBase: Float, amplitude: Float = 0.03) -> CIImage {
        PresenceScene.make(width: width, height: height) { x, y in
            let period = 4 * radius
            let wave = Float(sin(2 * .pi * Double(x) / period) * sin(2 * .pi * Double(y) / period))
            let level = x < width / 2 ? base : rightBase
            return PresenceScene.gray(level + amplitude * wave)
        }
    }

    static func contrast(_ image: CIImage, left: Bool) -> Float {
        let margin = Int(2 * radius)
        let x = left ? margin..<(width / 2 - margin) : (width / 2 + margin)..<(width - margin)
        return PresencePixels.deviation(PresencePixels(image).lumas(x: x, y: margin..<(height - margin)))
    }

    @Suite("apply")
    struct Apply {
        @Test("should leave a flat image unchanged at both extremes")
        func flat() {
            let input = TestImages.gray(level: 0.2, size: 64)
            for amount in [-100.0, 100] {
                let output = PresenceScene.apply(ClarityPlugin(), amount: amount, to: input)
                #expect(Pixels.maxDifference(between: output, and: input) < 1e-3)
            }
        }

        @Test("should not halo beside a strong edge")
        func noHalo() {
            let input = PresenceScene.make(width: ClarityTests.width, height: 32) { x, _ in
                PresenceScene.gray(x < ClarityTests.width / 2 ? 0.15 : 0.75)
            }
            let output = PresencePixels(PresenceScene.apply(ClarityPlugin(), amount: 100, to: input))
            let row = (0..<ClarityTests.width).map { output.luma(x: $0, y: 16) }
            #expect(row.max()! < 0.75 + 0.02)
            #expect(row.min()! > 0.15 - 0.02)
        }

        @Test("should raise midtone local contrast more than in deep shadows")
        func midtones() {
            let input = ClarityTests.ripples(base: 0.5, rightBase: 0.07, amplitude: 0.025)
            let output = PresenceScene.apply(ClarityPlugin(), amount: 100, to: input)
            let midGain = ClarityTests.contrast(output, left: true) / ClarityTests.contrast(input, left: true)
            let shadowGain = ClarityTests.contrast(output, left: false) / ClarityTests.contrast(input, left: false)
            #expect(midGain > 1.6)
            #expect(shadowGain < 1 + (midGain - 1) / 2)
        }

        @Test("should protect highlights")
        func highlights() {
            let input = ClarityTests.ripples(base: 0.5, rightBase: 0.95, amplitude: 0.025)
            let output = PresenceScene.apply(ClarityPlugin(), amount: 100, to: input)
            let midGain = ClarityTests.contrast(output, left: true) / ClarityTests.contrast(input, left: true)
            let highGain = ClarityTests.contrast(output, left: false) / ClarityTests.contrast(input, left: false)
            #expect(highGain < 1 + (midGain - 1) / 2)
        }

        @Test("should soften midtone local contrast at negative values")
        func softens() {
            let input = ClarityTests.ripples(base: 0.5, rightBase: 0.5)
            let full = ClarityTests.contrast(PresenceScene.apply(ClarityPlugin(), amount: -100, to: input), left: true)
            let half = ClarityTests.contrast(PresenceScene.apply(ClarityPlugin(), amount: -50, to: input), left: true)
            let before = ClarityTests.contrast(input, left: true)
            #expect(full < 0.5 * before)
            #expect(half < before && half > full)

        }

        @Test("should keep every pixel's hue")
        func hue() {
            let input = PresenceScene.make(width: 128, height: 64) { x, y in
                let wave = Float(1 + 0.4 * sin(Double(x) * 0.15) * sin(Double(y) * 0.15))
                return SIMD3(0.3, 0.15, 0.06) * wave
            }
            let output = PresencePixels(PresenceScene.apply(ClarityPlugin(), amount: 100, to: input))
            for y in stride(from: 4, to: 60, by: 9) {
                for x in stride(from: 4, to: 124, by: 9) {
                    let c = output.rgb(x: x, y: y)
                    #expect(abs(c.y / c.x - 0.5) < 0.005)
                    #expect(abs(c.z / c.x - 0.2) < 0.005)
                }
            }
        }

        @Test("should look the same in a half-size preview as in the downscaled export")
        func previewMatchesExport() {
            let input = ClarityTests.ripples(base: 0.45, rightBase: 0.3)
            let export = PresenceScene.apply(ClarityPlugin(), amount: 100, to: input)
            let small = GuidedFilter.downsample(input, scale: 0.5)
            let preview = PresencePixels(PresenceScene.apply(ClarityPlugin(), amount: 100, to: small, scale: 0.5))
            let exportSmall = PresencePixels(GuidedFilter.downsample(export, scale: 0.5))
            let original = PresencePixels(small)
            let inner = 16..<(ClarityTests.width / 2 - 16)
            let rows = 16..<(ClarityTests.height / 2 - 16)
            var mismatch: Float = 0
            var effect: Float = 0
            for y in rows {
                for x in inner {
                    mismatch += abs(preview.luma(x: x, y: y) - exportSmall.luma(x: x, y: y))
                    effect += abs(exportSmall.luma(x: x, y: y) - original.luma(x: x, y: y))
                }
            }
            #expect(mismatch < 0.2 * effect)
        }
    }
}
