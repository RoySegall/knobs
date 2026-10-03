import CoreImage
import Foundation
import Testing
@testable import KnobsKit

@Suite("TexturePlugin")
struct TextureTests {
    static let size = 128

    /// Mid-gray carrying a pattern of `period` pixels, amplitude in encoded units. Period 2 is a pixel checker.
    static func pattern(period: Double, amplitude: Float = 0.03, base: Float = 0.45) -> CIImage {
        PresenceScene.make(width: size, height: size) { x, y in
            let wave = period == 2
                ? Float((x + y) % 2 == 0 ? 1 : -1)
                : Float(sin(2 * .pi * Double(x) / period) * sin(2 * .pi * Double(y) / period))
            return PresenceScene.gray(base + amplitude * wave)
        }
    }

    /// Contrast gain of the pattern away from the borders.
    static func gain(amount: Double, period: Double) -> Float {
        let input = pattern(period: period)
        let output = PresenceScene.apply(TexturePlugin(), amount: amount, to: input)
        let inner = 8..<(size - 8)
        let before = PresencePixels.deviation(PresencePixels(input).lumas(x: inner, y: inner))
        let after = PresencePixels.deviation(PresencePixels(output).lumas(x: inner, y: inner))
        return after / before
    }

    /// Dark and bright halves with a hard vertical edge in the middle.
    static func edge(dark: Float = 0.1, bright: Float = 0.7, texture: Float = 0) -> CIImage {
        PresenceScene.make(width: size, height: 32) { x, y in
            let wave = texture * Float(sin(Double(x) * 1.3) * sin(Double(y) * 1.3))
            return PresenceScene.gray((x < size / 2 ? dark : bright) + wave)
        }
    }

    @Suite("apply")
    struct Apply {
        @Test("should leave a flat image unchanged at both extremes")
        func flat() {
            let input = TestImages.gray(level: 0.2, size: 64)
            for amount in [-100.0, 100] {
                let output = PresenceScene.apply(TexturePlugin(), amount: amount, to: input)
                #expect(Pixels.maxDifference(between: output, and: input) < 1e-3)
            }
        }

        @Test("should not ring around a strong edge when adding texture")
        func noRinging() {
            let output = PresencePixels(PresenceScene.apply(TexturePlugin(), amount: 100, to: TextureTests.edge()))
            let row = (0..<TextureTests.size).map { output.luma(x: $0, y: 16) }
            #expect(row.max()! < 0.7 + 0.015)
            #expect(row.min()! > 0.1 - 0.015)
        }

        @Test("should keep a strong edge sharp while smoothing the texture beside it")
        func edgeSurvivesSmoothing() {
            let input = TextureTests.edge(texture: 0.02)
            let output = PresencePixels(PresenceScene.apply(TexturePlugin(), amount: -100, to: input))
            let original = PresencePixels(input)
            let half = TextureTests.size / 2
            for y in 8..<24 {
                #expect(abs(output.luma(x: half - 1, y: y) - original.luma(x: half - 1, y: y)) < 0.03)
                #expect(abs(output.luma(x: half, y: y) - original.luma(x: half, y: y)) < 0.03)
            }
        }

        @Test("should boost medium-fine detail much more than pixel-level noise")
        func bandSelective() {
            let medium = TextureTests.gain(amount: 100, period: 8)
            let finest = TextureTests.gain(amount: 100, period: 2)
            #expect(medium > 1.8)
            #expect(finest < 1.25)
        }

        @Test("should leave broad tonal shapes alone")
        func broadUntouched() {
            let boosted = TextureTests.gain(amount: 100, period: 128)
            let smoothed = TextureTests.gain(amount: -100, period: 128)
            #expect(abs(boosted - 1) < 0.1)
            #expect(abs(smoothed - 1) < 0.1)
        }

        @Test("should smooth medium-fine detail at negative values")
        func smooths() {
            #expect(TextureTests.gain(amount: -100, period: 8) < 0.5)
            let half = TextureTests.gain(amount: -50, period: 8)
            #expect(half > 0.5 && half < 0.9)

        }

        @Test("should keep the average brightness")
        func tonality() {
            let input = TextureTests.pattern(period: 8)
            for amount in [-100.0, 100] {
                let output = PresenceScene.apply(TexturePlugin(), amount: amount, to: input)
                let inner = 8..<(TextureTests.size - 8)
                let before = PresencePixels.mean(PresencePixels(input).lumas(x: inner, y: inner))
                let after = PresencePixels.mean(PresencePixels(output).lumas(x: inner, y: inner))
                #expect(abs(after - before) < 0.005)
            }
        }

        @Test("should keep every pixel's hue")
        func hue() {
            let input = PresenceScene.make(width: 64, height: 64) { x, y in
                let wave = Float(1 + 0.3 * sin(Double(x) * 0.8) * sin(Double(y) * 0.8))
                return SIMD3(0.4, 0.2, 0.08) * wave
            }
            let output = PresencePixels(PresenceScene.apply(TexturePlugin(), amount: 100, to: input))
            for y in stride(from: 4, to: 60, by: 7) {
                for x in stride(from: 4, to: 60, by: 7) {
                    let c = output.rgb(x: x, y: y)
                    #expect(abs(c.y / c.x - 0.5) < 0.005)
                    #expect(abs(c.z / c.x - 0.2) < 0.005)
                }
            }
        }
    }
}
