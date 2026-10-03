import CoreImage
import Testing
@testable import KnobsKit

@Suite("BrightnessPlugin")
struct BrightnessTests {
    static func render(level: Float, brightness: Double) -> SIMD4<Float> {
        let plugin = BrightnessPlugin()
        let input = TestImages.gray(level: level)
        let values = KnobValues(params: plugin.params, stored: ["brightness": .number(brightness)])
        return Pixels.mean(plugin.apply(image: input, values: values, context: TestImages.context(for: input)))
    }

    @Suite("apply")
    struct Apply {
        @Test("should keep black and white where they are")
        func endpoints() {
            #expect(abs(BrightnessTests.render(level: 0, brightness: 100).x) < 1e-4)
            #expect(abs(BrightnessTests.render(level: 1, brightness: 100).x - 1) < 1e-3)
            #expect(abs(BrightnessTests.render(level: 1, brightness: -100).x - 1) < 1e-3)
        }

        @Test("should brighten midtones when positive and darken them when negative")
        func midtones() {
            #expect(BrightnessTests.render(level: 0.18, brightness: 50).x > 0.18 * 1.2)
            #expect(BrightnessTests.render(level: 0.18, brightness: -50).x < 0.18 / 1.2)
        }

        @Test("should keep a color's channel ratios")
        func hue() {
            let plugin = BrightnessPlugin()
            let input = TestImages.image(floats: [0.4, 0.2, 0.1, 1], width: 1, height: 1)
            let values = KnobValues(params: plugin.params, stored: ["brightness": .number(80)])
            let output = Pixels.read(plugin.apply(image: input, values: values, context: TestImages.context(for: input)))
            #expect(abs(output[0] / output[1] - 2) < 1e-3)
            #expect(abs(output[1] / output[2] - 2) < 1e-3)
        }
    }
}
