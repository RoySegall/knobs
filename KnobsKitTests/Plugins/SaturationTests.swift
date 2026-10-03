import CoreImage
import Testing
@testable import KnobsKit

@Suite("SaturationPlugin")
struct SaturationTests {
    static let plugin = SaturationPlugin()

    static func apply(amount: Double, to colors: [SIMD3<Double>]) -> [SIMD3<Double>] {
        ColorSwatches.apply(plugin: plugin, values: ["saturation": .number(amount)], to: colors)
    }

    static let colors = [
        ColorSwatches.encoded(red: 194, green: 150, blue: 130),
        ColorSwatches.encoded(red: 98, green: 122, blue: 157),
        ColorSwatches.encoded(red: 87, green: 108, blue: 67),
        ColorSwatches.encoded(red: 214, green: 126, blue: 44),
        ColorSwatches.encoded(red: 56, green: 61, blue: 150),
    ]

    @Suite("apply")
    struct Apply {
        @Test("should keep black, grays and HDR whites neutral and finite at both extremes")
        func neutrals() {
            let neutrals = [ColorSwatches.gray(0), ColorSwatches.gray(0.18), ColorSwatches.gray(3)]
            for amount in [-100.0, 100] {
                for (input, output) in zip(neutrals, SaturationTests.apply(amount: amount, to: neutrals)) {
                    #expect(output.x.isFinite && output.y.isFinite && output.z.isFinite)
                    #expect(abs(output.x - input.x) < 1e-3 * max(input.x, 1), "\(amount) \(input)")
                    #expect(abs(output.x - output.y) < 1e-4 && abs(output.y - output.z) < 1e-4)
                }
            }
        }

        @Test("should keep a fully saturated primary inside Display P3 at +100")
        func gamut() {
            let primaries = [SIMD3(1.0, 0, 0), SIMD3(0, 1.0, 0), SIMD3(0, 0, 1.0), SIMD3(0, 0.6, 0.6)]
            for output in SaturationTests.apply(amount: 100, to: primaries) {
                #expect(ColorSwatches.lowestP3(output) > -0.002, "\(output)")
            }
        }

        @Test("should turn colors into a neutral gray of equal luminance at -100")
        func monochrome() {
            let output = SaturationTests.apply(amount: -100, to: SaturationTests.colors)
            for (input, gray) in zip(SaturationTests.colors, output) {
                #expect(abs(gray.x - gray.y) < 1e-4 && abs(gray.y - gray.z) < 1e-4, "\(gray)")
                #expect(abs(ColorSwatches.luminance(gray) - ColorSwatches.luminance(input)) < 1e-4)
            }
        }

        @Test("should halve chroma at -50 without moving hue")
        func halves() {
            let output = SaturationTests.apply(amount: -50, to: SaturationTests.colors)
            for (input, muted) in zip(SaturationTests.colors, output) {
                #expect(abs(ColorSwatches.chroma(muted) / ColorSwatches.chroma(input) - 0.5) < 0.05)
                #expect(abs(ColorSwatches.hueDistance(from: ColorSwatches.hue(muted), to: ColorSwatches.hue(input))) < 0.5)
            }
        }

        @Test("should raise chroma at +100 keeping hue and OKLab lightness")
        func boosts() {
            let output = SaturationTests.apply(amount: 100, to: SaturationTests.colors)
            for (input, boosted) in zip(SaturationTests.colors, output) {
                let ratio = ColorSwatches.chroma(boosted) / ColorSwatches.chroma(input)
                #expect(ratio > 1.2 && ratio <= 2.001, "\(input) gained \(ratio)")
                #expect(abs(ColorSwatches.hueDistance(from: ColorSwatches.hue(boosted), to: ColorSwatches.hue(input))) < 0.5)
                #expect(abs(ColorSwatches.lab(boosted).x - ColorSwatches.lab(input).x) < 1e-3)
            }
        }

        @Test("should double the chroma of a muted color at +100")
        func doubles() {
            let muted = ColorSwatches.color(lightness: 0.6, chroma: 0.04, hue: 140)
            let boosted = SaturationTests.apply(amount: 100, to: [muted])[0]
            #expect(abs(ColorSwatches.chroma(boosted) - 0.08) < 2e-3)
        }
    }
}
