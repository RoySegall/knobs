import CoreImage
import simd
import Testing
@testable import KnobsKit

@Suite("GuidedFilter")
struct GuidedFilterTests {
    static let size = 64

    /// Two colors of equal luminance meeting at a vertical edge, with mild noise.
    static func guide() -> CIImage {
        PresenceScene.make(width: size, height: size) { x, y in
            let n = 0.01 * (PresenceScene.noise(x: x, y: y) - 0.5)
            return (x < size / 2 ? SIMD3<Float>(0.6, 0.3, 0.3) : SIMD3<Float>(0.3, 0.45, 0.45)) + n
        }
    }

    /// q = dot(a, I) + b at every pixel.
    static func refined(coefficients: CIImage, guide: CIImage) -> [Float] {
        let a = PresencePixels(coefficients)
        let g = PresencePixels(guide)
        return (0..<size).flatMap { y in
            (0..<size).map { x in
                let index = (y * size + x) * 4
                return simd_dot(a.rgb(x: x, y: y), g.rgb(x: x, y: y)) + a.rgba[index + 3]
            }
        }
    }

    @Suite("colorCoefficients")
    struct Color {
        @Test("should smooth an input that has no matching structure in the guide")
        func smoothsNoise() {
            let flat = PresenceScene.make(width: size, height: size) { _, _ in SIMD3(repeating: 0.5) }
            let noisy = PresenceScene.make(width: size, height: size) { x, y in
                SIMD3(repeating: 0.5 + 0.2 * (PresenceScene.noise(x: x, y: y) - 0.5))
            }
            let coefficients = GuidedFilter.colorCoefficients(guide: flat, input: noisy, radius: 4, epsilon: 1e-3)
            let output = refined(coefficients: coefficients, guide: flat)
            let deviation = PresencePixels.deviation(output)
            #expect(deviation < 0.01)
            #expect(abs(PresencePixels.mean(output) - 0.5) < 0.01)
        }

        @Test("should follow an edge that only shows in color, not in luminance")
        func colorEdge() {
            let input = PresenceScene.make(width: size, height: size) { x, _ in SIMD3(repeating: x < size / 2 ? 0.2 : 0.8) }
            let coefficients = GuidedFilter.colorCoefficients(guide: guide(), input: input, radius: 6, epsilon: 1e-4)
            let output = refined(coefficients: coefficients, guide: guide())
            for y in [8, 32, 56] {
                #expect(abs(output[y * size + size / 2 - 2] - 0.2) < 0.05)
                #expect(abs(output[y * size + size / 2 + 1] - 0.8) < 0.05)
            }
        }
    }

    @Suite("grayCoefficients")
    struct Gray {
        @Test("should flatten low-contrast ripples and keep a strong edge")
        func edgeAware() {
            let input = PresenceScene.make(width: size, height: size) { x, y in
                let ripple = 0.02 * Float(sin(Double(x) * 0.9) * sin(Double(y) * 0.9))
                return SIMD3(repeating: (x < size / 2 ? 0.2 : 0.8) + ripple)
            }
            let coefficients = PresencePixels(GuidedFilter.grayCoefficients(guide: input, radius: 5, epsilon: 0.005))
            let original = PresencePixels(input)
            let output = (0..<size).map { x -> Float in
                let ab = coefficients.rgb(x: x, y: 32)
                return ab.x * original.rgb(x: x, y: 32).x + ab.y
            }
            #expect(abs(output[size / 2 - 1] - 0.2) < 0.05)
            #expect(abs(output[size / 2] - 0.8) < 0.05)
            let flatSide = Array(output[4..<20])
            #expect(PresencePixels.deviation(flatSide) < 0.004)
        }
    }
}
