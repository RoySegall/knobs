import CoreImage
import simd
import Testing
@testable import KnobsKit

@Suite("WhiteBalancePlugin")
struct WhiteBalanceTests {
    typealias WhiteBalance = WhiteBalancePlugin.WhiteBalance

    static func applied(color: SIMD3<Float>, temp: Double = 0, tint: Double = 0) -> SIMD3<Float> {
        let plugin = WhiteBalancePlugin()
        let image = TestImages.image(floats: [color.x, color.y, color.z, 1], width: 1, height: 1)
        let values = KnobValues(params: plugin.params, stored: ["temp": .number(temp), "tint": .number(tint)])
        let pixel = Pixels.read(plugin.apply(image: image, values: values, context: TestImages.context(for: image)))
        return SIMD3(pixel[0], pixel[1], pixel[2])
    }

    static func luminance(_ color: SIMD3<Float>) -> Float {
        0.2126 * color.x + 0.7152 * color.y + 0.0722 * color.z
    }

    @Suite("WhiteBalance.shifted")
    struct Shifted {
        @Test("should stop at 2000 K and 50000 K however far the slider pushes")
        func clamps() {
            #expect(abs(WhiteBalance(temperature: 2500, tint: 0).shifted(temp: -100, tint: 0).temperature - 2000) < 1e-6)
            #expect(abs(WhiteBalance(temperature: 20000, tint: 0).shifted(temp: 100, tint: 0).temperature - 50000) < 1e-6)
        }

        @Test("should move temperature in equal mired steps, warmer for plus")
        func miredSteps() {
            let shifted = WhiteBalance(temperature: 5000, tint: 0).shifted(temp: 10, tint: 0)
            #expect(abs(1e6 / shifted.temperature - (200 - 10 * WhiteBalancePlugin.miredsPerStep)) < 1e-9)
            #expect(shifted.temperature > 5000)
        }

        @Test("should add tint in Adobe units on top of the as-shot tint")
        func tint() {
            let shifted = WhiteBalance(temperature: 5000, tint: 9.5).shifted(temp: 0, tint: -30)
            #expect(shifted.tint == -20.5)
            #expect(shifted.temperature == 5000)
        }
    }

    @Suite("WhiteBalance.chromaticity")
    struct Chromaticity {
        // Pairs CIRAWFilter reported for real as-shot DNGs, so bitmaps and RAW share one scale.
        @Test("should match CIRAWFilter's temperature and tint", arguments: [
            (6266.027, 6.290218, 0.31694114, 0.33077174),
            (6631.4976, 51.420708, 0.30683133, 0.35155788),
            (4686.31, -2.4290664, 0.354215, 0.356880),
        ])
        func matchesDecoder(temperature: Double, tint: Double, x: Double, y: Double) {
            let chromaticity = WhiteBalance(temperature: temperature, tint: tint).chromaticity
            #expect(abs(chromaticity.x - x) < 1e-5)
            #expect(abs(chromaticity.y - y) < 1e-5)
        }

        @Test("should put the D50 reference at D50")
        func d50() {
            let chromaticity = WhiteBalance.d50.chromaticity
            #expect(abs(chromaticity.x - 0.3457) < 1e-5)
            #expect(abs(chromaticity.y - 0.3585) < 1e-5)
        }
    }

    @Suite("adaptation")
    struct Adaptation {
        @Test("should carry the source white onto the target white, not just rescale channels")
        func mapsWhites() {
            let source = WhiteBalance(temperature: 3200, tint: 0).chromaticity
            let target = WhiteBalance.d50.chromaticity
            let m = WhiteBalancePlugin.adaptation(from: source, to: target)
            let sourceRGB = Self.linearSRGB(source)
            let mapped = (0..<3).map { row in (0..<3).reduce(0) { $0 + m[row][$1] * sourceRGB[$1] } }
            let targetRGB = Self.linearSRGB(target)
            for channel in 0..<3 {
                #expect(abs(mapped[channel] / mapped[1] - targetRGB[channel] / targetRGB[1]) < 1e-4)
            }
        }

        static func linearSRGB(_ chromaticity: WhiteBalancePlugin.Chromaticity) -> [Double] {
            let xyz = chromaticity.whiteXYZ
            return [
                3.2404542 * xyz[0] - 1.5371385 * xyz[1] - 0.4985314 * xyz[2],
                -0.9692660 * xyz[0] + 1.8760108 * xyz[1] + 0.0415560 * xyz[2],
                0.0556434 * xyz[0] - 0.2040259 * xyz[1] + 1.0572252 * xyz[2],
            ]
        }
    }

    @Suite("apply")
    struct Apply {
        @Test("should cool a gray with minus temp and warm it with plus")
        func temperature() {
            let cool = WhiteBalanceTests.applied(color: SIMD3(repeating: 0.18), temp: -50)
            let warm = WhiteBalanceTests.applied(color: SIMD3(repeating: 0.18), temp: 50)
            #expect(cool.z > cool.x)
            #expect(warm.x > warm.y)
            #expect(warm.y > warm.z)
        }

        @Test("should turn a gray green with minus tint and magenta with plus")
        func tint() {
            let green = WhiteBalanceTests.applied(color: SIMD3(repeating: 0.18), tint: -50)
            let magenta = WhiteBalanceTests.applied(color: SIMD3(repeating: 0.18), tint: 50)
            #expect(green.y > (green.x + green.z) / 2)
            #expect(magenta.y < (magenta.x + magenta.z) / 2)
        }

        @Test("should keep a gray's luminance at the slider ends", arguments: [(-100.0, 0.0), (100.0, 0.0), (0.0, -100.0), (0.0, 100.0)])
        func luminance(temp: Double, tint: Double) {
            let output = WhiteBalanceTests.applied(color: SIMD3(repeating: 0.18), temp: temp, tint: tint)
            #expect(abs(WhiteBalanceTests.luminance(output) - 0.18) < 1e-3)
        }

        @Test("should act linearly on light, so twice the light stays twice the light")
        func linear() {
            let color = SIMD3<Float>(0.3, 0.2, 0.1)
            let single = WhiteBalanceTests.applied(color: color, temp: 60, tint: -20)
            let double = WhiteBalanceTests.applied(color: color * 2, temp: 60, tint: -20)
            #expect(simd_reduce_max(abs(double - single * 2)) < 1e-3)
        }

        @Test("should grow its effect evenly with the slider, without a jump off zero")
        func even() {
            let gray = SIMD3<Float>(repeating: 0.18)
            let small = simd_reduce_max(abs(WhiteBalanceTests.applied(color: gray, temp: 5) - gray))
            let large = simd_reduce_max(abs(WhiteBalanceTests.applied(color: gray, temp: 50) - gray))
            #expect(small > 0)
            #expect(large / small > 6)
            #expect(large / small < 14)
        }
    }
}
