import CoreImage
import Testing
@testable import KnobsKit

@Suite("ColorGradingPlugin")
struct ColorGradingTests {
    static let plugin = ColorGradingPlugin()

    static func apply(values: [String: KnobValue], to colors: [SIMD3<Double>]) -> [SIMD3<Double>] {
        ColorSwatches.apply(plugin: plugin, values: values, to: colors)
    }

    /// Neutral gray at an OKLab lightness.
    static func gray(lightness: Double) -> SIMD3<Double> {
        ColorSwatches.gray(pow(lightness, 3))
    }

    @Suite("apply")
    struct Apply {
        @Test("should do nothing while every wheel and luminance is neutral, whatever blending and balance say")
        func neutral() {
            let input = TestImages.detail()
            let plugin = ColorGradingTests.plugin
            let values = KnobValues(params: plugin.params, stored: ["blending": .number(0), "balance": .number(100)])
            let output = plugin.apply(image: input, values: values, context: TestImages.context(for: input))
            #expect(Pixels.maxDifference(between: output, and: input) < 1e-6)
        }

        @Test("should keep pure black neutral under every wheel")
        func black() {
            let wheel = KnobValue.wheel(Wheel(hue: 210, amount: 1))
            let output = ColorGradingTests.apply(values: ["shadows": wheel, "global": wheel], to: [ColorSwatches.gray(0)])[0]
            #expect(abs(output.x) < 1e-4 && abs(output.y) < 1e-4 && abs(output.z) < 1e-4)
        }

        @Test("should tint dark pixels more than bright ones from the shadows wheel")
        func shadows() {
            let grays = [ColorGradingTests.gray(lightness: 0.3), ColorGradingTests.gray(lightness: 0.9)]
            let output = ColorGradingTests.apply(values: ["shadows": .wheel(Wheel(hue: 210, amount: 0.5))], to: grays)
            #expect(ColorSwatches.chroma(output[0]) > 0.01)
            #expect(ColorSwatches.chroma(output[1]) < 0.002)
        }

        @Test("should tint bright pixels toward the highlights wheel's hue at constant lightness")
        func highlights() {
            let grays = [ColorGradingTests.gray(lightness: 0.3), ColorGradingTests.gray(lightness: 0.9)]
            let output = ColorGradingTests.apply(values: ["highlights": .wheel(Wheel(hue: 40, amount: 0.5))], to: grays)
            let expected = ColorOKLab.hue(wheelHue: 40)
            #expect(ColorSwatches.chroma(output[1]) > 0.04)
            #expect(ColorSwatches.chroma(output[0]) < ColorSwatches.chroma(output[1]) / 4)
            #expect(abs(ColorSwatches.hueDistance(from: ColorSwatches.hue(output[1]), to: expected)) < 0.5)
            #expect(abs(ColorSwatches.lab(output[1]).x - 0.9) < 1e-3)
        }

        @Test("should tint every tone from the global wheel")
        func global() {
            let grays = [0.2, 0.5, 0.9].map { ColorGradingTests.gray(lightness: $0) }
            let output = ColorGradingTests.apply(values: ["global": .wheel(Wheel(hue: 120, amount: 0.5))], to: grays)
            for (gray, tinted) in zip([0.2, 0.5, 0.9], output) {
                #expect(abs(ColorSwatches.chroma(tinted) / gray - 0.5 * ColorGradingPlugin.tintStrength) < 1e-3)
            }
        }

        @Test("should hand midtones to the highlights wheel as balance rises")
        func balance() {
            let midtone = [ColorGradingTests.gray(lightness: 0.45)]
            let wheel = KnobValue.wheel(Wheel(hue: 40, amount: 0.6))
            let low = ColorGradingTests.apply(values: ["highlights": wheel, "balance": .number(-100)], to: midtone)[0]
            let high = ColorGradingTests.apply(values: ["highlights": wheel, "balance": .number(100)], to: midtone)[0]
            #expect(ColorSwatches.chroma(high) > ColorSwatches.chroma(low) * 2)
        }

        @Test("should spread the shadows tint further up with more blending")
        func blending() {
            let upper = [ColorGradingTests.gray(lightness: 0.6)]
            let wheel = KnobValue.wheel(Wheel(hue: 210, amount: 0.6))
            let hard = ColorGradingTests.apply(values: ["shadows": wheel, "blending": .number(0)], to: upper)[0]
            let soft = ColorGradingTests.apply(values: ["shadows": wheel, "blending": .number(100)], to: upper)[0]
            #expect(ColorSwatches.chroma(hard) < 1e-3)
            #expect(ColorSwatches.chroma(soft) > 0.01)
        }

        @Test("should brighten shadows with shadows luminance and leave highlights nearly alone")
        func luminance() {
            let grays = [ColorGradingTests.gray(lightness: 0.25), ColorGradingTests.gray(lightness: 0.95)]
            let output = ColorGradingTests.apply(values: ["shadows_luminance": .number(100)], to: grays)
            #expect(ColorSwatches.lab(output[0]).x > 0.25 * 1.15)
            #expect(abs(ColorSwatches.lab(output[1]).x - 0.95) < 0.005)
            #expect(ColorSwatches.chroma(output[0]) < 1e-3)
        }
    }
}
