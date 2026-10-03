import CoreImage
import Testing
@testable import KnobsKit

@Suite("ExposurePlugin")
struct ExposureTests {
    static func applied(colors: [SIMD3<Float>], stops: Double) -> [SIMD3<Float>] {
        let plugin = ExposurePlugin()
        let floats: [Float] = colors.flatMap { [$0.x, $0.y, $0.z, 1] }
        let image = TestImages.image(floats: floats, width: colors.count, height: 1)
        let values = KnobValues(params: plugin.params, stored: ["exposure": .number(stops)])
        let pixels = Pixels.read(plugin.apply(image: image, values: values, context: TestImages.context(for: image)))
        return stride(from: 0, to: pixels.count, by: 4).map { SIMD3(pixels[$0], pixels[$0 + 1], pixels[$0 + 2]) }
    }

    static func gray(_ level: Float) -> SIMD3<Float> {
        SIMD3(repeating: level)
    }

    @Suite("apply")
    struct Apply {
        @Test("should stay monotonic from black to past white at every push", arguments: [0.01, 1, 5])
        func monotonic(stops: Double) {
            let ramp = (0..<64).map { ExposureTests.gray(Float($0) / 40) }
            let output = ExposureTests.applied(colors: ramp, stops: stops)
            for index in 1..<output.count {
                #expect(output[index].x > output[index - 1].x)
            }
        }

        @Test("should barely move anything for a tiny push")
        func continuous() {
            let levels = [0.1, 0.5, 0.9, 1].map(ExposureTests.gray)
            let output = ExposureTests.applied(colors: levels, stops: 0.01)
            for (before, after) in zip(levels, output) {
                #expect(abs(after.x - before.x) < 0.01)
            }
        }

        @Test("should scale light exactly when pulling down")
        func pull() {
            let output = ExposureTests.applied(colors: [ExposureTests.gray(0.8), ExposureTests.gray(3)], stops: -1)
            #expect(abs(output[0].x - 0.4) < 1e-4)
            #expect(abs(output[1].x - 1.5) < 1e-3)
        }

        @Test("should scale mid-tones exactly and land the source white on white when pushing")
        func push() {
            let output = ExposureTests.applied(colors: [ExposureTests.gray(0.1), ExposureTests.gray(1)], stops: 2)
            #expect(abs(output[0].x - 0.4) < 1e-4)
            #expect(abs(output[1].x - 1) < 1e-3)
        }

        @Test("should fade a pushed bright color toward white without turning its hue")
        func hue() {
            let skin = SIMD3<Float>(0.8, 0.5, 0.35)
            let output = ExposureTests.applied(colors: [skin], stops: 2)[0]
            #expect(output.x <= 1 + 1e-4)
            #expect(output.x > output.y)
            #expect(output.y > output.z)
            #expect(abs((output.y - output.z) / (output.x - output.z) - (0.5 - 0.35) / (0.8 - 0.35)) < 1e-3)
            #expect((output.x - output.z) / output.x < (skin.x - skin.z) / skin.x)
        }
    }
}
