import CoreImage
import Testing
@testable import KnobsKit

private enum Fixture {
    static let size = 64

    /// Mid-gray with seeded luma noise and seeded chroma noise, both sigma ~0.03 in sRGB-encoded units.
    static func noisy(luma: Float, chroma: Float) -> CIImage {
        var random = SplitMix(seed: 42)
        return image { _, _ in
            let y = 0.5 + luma * random.gaussian()
            return rgb(y: y, blue: chroma * random.gaussian(), red: chroma * random.gaussian())
        }
    }

    /// Two flat halves whose colors differ but whose luma matches: a color edge with no luma edge to follow.
    static func colorEdge() -> CIImage {
        image { x, _ in x < size / 2 ? rgb(y: 0.5, blue: -0.15, red: 0.2) : rgb(y: 0.5, blue: 0.2, red: -0.15) }
    }

    /// Dark left half, bright right half.
    static func lumaEdge() -> CIImage {
        image { x, _ in x < size / 2 ? rgb(y: 0.2, blue: 0, red: 0) : rgb(y: 0.8, blue: 0, red: 0) }
    }

    static func image(pixel: (Int, Int) -> SIMD3<Float>) -> CIImage {
        var floats = [Float](repeating: 1, count: size * size * 4)
        for y in 0..<size {
            for x in 0..<size {
                let value = pixel(x, y)
                let index = (y * size + x) * 4
                floats[index] = value.x
                floats[index + 1] = value.y
                floats[index + 2] = value.z
            }
        }
        return TestImages.image(floats: floats, width: size, height: size)
    }

    /// Linear RGB from sRGB-encoded luma and blue/red differences, the plugin's own opponent space.
    static func rgb(y: Float, blue: Float, red: Float) -> SIMD3<Float> {
        let b = y + blue
        let r = y + red
        let g = (y - 0.2126 * r - 0.0722 * b) / 0.7152
        return SIMD3(linear(r), linear(g), linear(b))
    }

    static func linear(_ value: Float) -> Float {
        value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }

    static func gamma(_ value: Float) -> Float {
        value <= 0.0031308 ? value * 12.92 : 1.055 * pow(value, 1 / 2.4) - 0.055
    }

    /// Variance of sRGB-encoded luma and of the blue/red differences over the inner pixels.
    static func variances(_ image: CIImage) -> (luma: Float, chroma: Float) {
        let floats = Pixels.read(image)
        var lumas: [Float] = []
        var chromas: [Float] = []
        for y in 8..<(size - 8) {
            for x in 8..<(size - 8) {
                let index = (y * size + x) * 4
                let r = gamma(floats[index])
                let g = gamma(floats[index + 1])
                let b = gamma(floats[index + 2])
                let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
                lumas.append(luma)
                chromas.append(b - luma)
                chromas.append(r - luma)
            }
        }
        return (variance(lumas), variance(chromas))
    }

    static func variance(_ values: [Float]) -> Float {
        let mean = values.reduce(0, +) / Float(values.count)
        return values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Float(values.count)
    }

    static func apply(_ image: CIImage, _ stored: [String: Double]) -> CIImage {
        let plugin = NoiseReductionPlugin()
        let values = KnobValues(params: plugin.params, stored: stored.mapValues { .number($0) })
        return plugin.apply(image: image, values: values, context: TestImages.context(for: image))
    }

    static func pixel(_ image: CIImage, x: Int, y: Int) -> SIMD3<Float> {
        let floats = Pixels.read(image)
        let index = (y * size + x) * 4
        return SIMD3(floats[index], floats[index + 1], floats[index + 2])
    }
}

/// Deterministic Gaussian noise for fixtures.
private struct SplitMix {
    var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func uniform() -> Float {
        Float(next() >> 40) / Float(1 << 24)
    }

    mutating func gaussian() -> Float {
        let u1 = max(uniform(), 1e-7)
        let u2 = uniform()
        return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }
}

@Suite("NoiseReductionPlugin")
struct NoiseReductionTests {
    @Suite("apply")
    struct Apply {
        @Test("should leave the image untouched when only the detail sliders moved")
        func detailOnly() {
            let input = Fixture.noisy(luma: 0.03, chroma: 0.03)
            let output = Fixture.apply(input, ["luminance_detail": 90, "color_detail": 10])
            #expect(Pixels.maxDifference(between: output, and: input) == 0)
        }

        @Test("should keep a luma edge sharp while smoothing luminance")
        func keepsLumaEdge() {
            let output = Fixture.apply(Fixture.lumaEdge(), ["luminance": 100])
            let dark = Fixture.pixel(output, x: Fixture.size / 2 - 1, y: 32)
            let bright = Fixture.pixel(output, x: Fixture.size / 2, y: 32)
            #expect(Fixture.gamma(dark.y) < 0.25)
            #expect(Fixture.gamma(bright.y) > 0.75)
        }

        @Test("should keep a color edge between equally bright colors at default color detail")
        func keepsColorEdge() {
            let input = Fixture.colorEdge()
            let output = Fixture.apply(input, ["color": 50])
            for x in [Fixture.size / 2 - 3, Fixture.size / 2 + 2] {
                let before = Fixture.pixel(input, x: x, y: 32)
                let after = Fixture.pixel(output, x: x, y: 32)
                #expect(abs(before.x - after.x) < 0.02, "x = \(x)")
                #expect(abs(before.z - after.z) < 0.02, "x = \(x)")
            }
        }

        @Test("should lower luma noise variance on a flat noisy patch")
        func lowersLumaNoise() {
            let input = Fixture.noisy(luma: 0.03, chroma: 0)
            let before = Fixture.variances(input).luma
            let after = Fixture.variances(Fixture.apply(input, ["luminance": 50])).luma
            #expect(after < before * 0.3)
        }

        @Test("should keep more texture at a higher luminance detail")
        func detailKeepsTexture() {
            let input = Fixture.noisy(luma: 0.03, chroma: 0)
            let smooth = Fixture.variances(Fixture.apply(input, ["luminance": 50, "luminance_detail": 0])).luma
            let detailed = Fixture.variances(Fixture.apply(input, ["luminance": 50, "luminance_detail": 100])).luma
            #expect(detailed > smooth * 2)
        }

        @Test("should lower chroma noise and leave luma alone when only color is set")
        func lowersChromaNoise() {
            let input = Fixture.noisy(luma: 0.03, chroma: 0.03)
            let before = Fixture.variances(input)
            let after = Fixture.variances(Fixture.apply(input, ["color": 50]))
            #expect(after.chroma < before.chroma * 0.1)
            #expect(abs(after.luma - before.luma) < before.luma * 0.05)
        }
    }
}
