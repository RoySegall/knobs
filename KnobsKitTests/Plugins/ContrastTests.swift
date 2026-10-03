import CoreImage
import Testing
@testable import KnobsKit

@Suite("ContrastPlugin")
struct ContrastTests {
    /// Runs one row of colors through the plugin and returns them in the same order.
    static func applied(colors: [SIMD3<Float>], contrast: Double) -> [SIMD3<Float>] {
        let plugin = ContrastPlugin()
        let floats: [Float] = colors.flatMap { [$0.x, $0.y, $0.z, 1] }
        let image = TestImages.image(floats: floats, width: colors.count, height: 1)
        let values = KnobValues(params: plugin.params, stored: ["contrast": .number(contrast)])
        let pixels = Pixels.read(plugin.apply(image: image, values: values, context: TestImages.context(for: image)))
        return stride(from: 0, to: pixels.count, by: 4).map { SIMD3(pixels[$0], pixels[$0 + 1], pixels[$0 + 2]) }
    }

    static func gray(_ level: Float) -> SIMD3<Float> {
        SIMD3(repeating: level)
    }

    @Suite("apply")
    struct Apply {
        @Test("should not push out-of-gamut channels further out when flattening", arguments: [-100.0, -50.0])
        func outOfGamut(contrast: Double) {
            let color = SIMD3<Float>(1.3, 0.2, -0.05)
            let output = ContrastTests.applied(colors: [color], contrast: contrast)[0]
            #expect(output.x <= color.x + 1e-4)
            #expect(output.z >= color.z - 1e-4)
        }

        @Test("should stay monotonic from black to well past white", arguments: [-100.0, 100.0])
        func monotonic(contrast: Double) {
            let ramp = (0..<64).map { ContrastTests.gray(Float($0) / 40) }
            let output = ContrastTests.applied(colors: ramp, contrast: contrast)
            for index in 1..<output.count {
                #expect(output[index].x > output[index - 1].x)
            }
        }

        @Test("should hold black, mid-gray and white in place", arguments: [-100.0, 100.0])
        func fixedPoints(contrast: Double) {
            let output = ContrastTests.applied(colors: [0, 0.18, 1].map(ContrastTests.gray), contrast: contrast)
            #expect(abs(output[0].x) < 1e-4)
            #expect(abs(output[1].x - 0.18) < 2e-3)
            #expect(abs(output[2].x - 1) < 1e-3)
        }

        @Test("should darken shadows and brighten highlights with plus, the reverse with minus")
        func direction() {
            let levels = [0.03, 0.6].map(ContrastTests.gray)
            let plus = ContrastTests.applied(colors: levels, contrast: 60)
            let minus = ContrastTests.applied(colors: levels, contrast: -60)
            #expect(plus[0].x < 0.03)
            #expect(plus[1].x > 0.6)
            #expect(minus[0].x > 0.03)
            #expect(minus[1].x < 0.6)
        }

        @Test("should keep hue: channel order and the middle channel's place between the others")
        func hue() {
            let color = SIMD3<Float>(0.5, 0.3, 0.1)
            for contrast in [-100.0, 100.0] {
                let output = ContrastTests.applied(colors: [color], contrast: contrast)[0]
                #expect(output.x > output.y)
                #expect(output.y > output.z)
                #expect(abs((output.y - output.z) / (output.x - output.z) - 0.5) < 1e-3)
            }
        }
    }
}
