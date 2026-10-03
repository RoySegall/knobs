import CoreImage
import Foundation
import simd
import Testing
@testable import KnobsKit

@Suite("LensCorrectionsPlugin")
struct LensCorrectionsTests {
    static let plugin = LensCorrectionsPlugin()
    static let width = 192
    static let height = 96
    static let edgeX = 96
    static let dark = SIMD3<Float>(repeating: 0.03)
    static let bright = SIMD3<Float>(0.85, 0.84, 0.82)
    /// OKLab hue 315: inside the default purple band. The green one is at 142, inside the default green band.
    static let purpleFringe = SIMD3<Float>(0.16, 0.04, 0.24)
    static let greenFringe = SIMD3<Float>(0.06, 0.2, 0.05)
    /// A purple object at the fringe's hue, bright enough to make a strong edge against black.
    static let purpleObject = SIMD3<Float>(0.6, 0.15, 0.95)

    /// Dark left, bright right, with a band of `fringe` on the dark side that is strongest at the edge.
    static func fringed(_ fringe: SIMD3<Float>, band: Int = 6, width: Int = width, edgeX: Int = edgeX) -> CIImage {
        PresenceScene.make(width: width, height: height) { x, _ in
            if x >= edgeX {
                return bright
            }
            let distance = edgeX - x
            guard distance <= band else { return dark }
            return dark + (fringe - dark) * (Float(band - distance + 1) / Float(band))
        }
    }

    static func apply(_ image: CIImage, values: [String: KnobValue], scale: Double = 1) -> CIImage {
        let values = KnobValues(params: plugin.params, stored: values)
        return plugin.apply(image: image, values: values, context: PresenceScene.context(for: image, scale: scale))
    }

    static func chroma(_ color: SIMD3<Float>) -> Double {
        ColorSwatches.chroma(SIMD3<Double>(color))
    }

    static func luminance(_ color: SIMD3<Float>) -> Double {
        ColorSwatches.luminance(SIMD3<Double>(color))
    }

    /// The fringe's pixels on the middle row, before and after.
    static func fringeRow(_ input: CIImage, _ output: CIImage, band: Int = 6, edgeX: Int = edgeX) -> [(SIMD3<Float>, SIMD3<Float>)] {
        let before = PresencePixels(input)
        let after = PresencePixels(output)
        return ((edgeX - band)..<edgeX).map { x in (before.rgb(x: x, y: height / 2), after.rgb(x: x, y: height / 2)) }
    }

    @Suite("apply")
    struct Apply {
        @Test("should return the input unchanged when both amounts are zero, whatever the hue ranges")
        func zeroAmounts() {
            let input = LensCorrectionsTests.fringed(LensCorrectionsTests.purpleFringe)
            let output = LensCorrectionsTests.apply(input, values: [
                "purple_hue_from": .number(0), "purple_hue_to": .number(100),
                "green_hue_from": .number(0), "green_hue_to": .number(100),
            ])
            #expect(output.extent == input.extent)
            #expect(Pixels.maxDifference(between: output, and: input) == 0)
        }

        @Test("should leave a purple patch away from strong edges untouched")
        func softPatch() {
            let object = LensCorrectionsTests.purpleObject
            let input = PresenceScene.make(width: LensCorrectionsTests.width, height: LensCorrectionsTests.height) { x, y in
                let distance = Float(hypot(Double(x - 96), Double(y - 48)))
                return PresenceScene.gray(0.45) + (object - PresenceScene.gray(0.45)) * exp(-distance * distance / 800)
            }
            let output = LensCorrectionsTests.apply(input, values: ["purple_amount": .number(100)])
            #expect(Pixels.maxDifference(between: output, and: input) < 1e-3)
        }

        @Test("should keep the rim of a purple object whose color fills its interior")
        func objectRim() {
            let object = LensCorrectionsTests.purpleObject
            let input = PresenceScene.make(width: LensCorrectionsTests.width, height: LensCorrectionsTests.height) { x, y in
                hypot(Double(x - 96), Double(y - 48)) < 36 ? object : SIMD3(repeating: 0.005)
            }
            let before = PresencePixels(input)
            let after = PresencePixels(LensCorrectionsTests.apply(input, values: ["purple_amount": .number(100)]))
            for x in 60...64 {
                let kept = LensCorrectionsTests.chroma(after.rgb(x: x, y: 48)) / LensCorrectionsTests.chroma(before.rgb(x: x, y: 48))
                #expect(kept > 0.9, "x \(x) kept \(kept)")
            }
        }

        @Test("should leave a purple fringe alone when only the green amount is set")
        func otherBand() {
            let input = LensCorrectionsTests.fringed(LensCorrectionsTests.purpleFringe)
            let output = LensCorrectionsTests.apply(input, values: ["green_amount": .number(100)])
            #expect(Pixels.maxDifference(between: output, and: input) < 1e-3)
        }

        @Test("should leave a purple fringe alone when the hue sliders exclude it")
        func outsideHueRange() {
            let input = LensCorrectionsTests.fringed(LensCorrectionsTests.purpleFringe)
            let output = LensCorrectionsTests.apply(input, values: [
                "purple_amount": .number(100), "purple_hue_from": .number(80), "purple_hue_to": .number(100),
            ])
            #expect(Pixels.maxDifference(between: output, and: input) < 1e-3)
        }

        @Test("should remove most of a purple fringe's chroma on a hard edge")
        func purpleFringe() {
            let input = LensCorrectionsTests.fringed(LensCorrectionsTests.purpleFringe)
            let output = LensCorrectionsTests.apply(input, values: ["purple_amount": .number(100)])
            for (before, after) in LensCorrectionsTests.fringeRow(input, output) {
                #expect(LensCorrectionsTests.chroma(after) < 0.2 * LensCorrectionsTests.chroma(before), "\(before) → \(after)")
            }
        }

        @Test("should keep each fringe pixel's luminance")
        func luminance() {
            let input = LensCorrectionsTests.fringed(LensCorrectionsTests.purpleFringe)
            let output = LensCorrectionsTests.apply(input, values: ["purple_amount": .number(100)])
            for (before, after) in LensCorrectionsTests.fringeRow(input, output) {
                let ratio = LensCorrectionsTests.luminance(after) / LensCorrectionsTests.luminance(before)
                #expect(abs(ratio - 1) < 2e-3, "\(before) → \(after)")
            }
        }

        @Test("should remove most of a green fringe's chroma on a hard edge")
        func greenFringe() {
            let input = LensCorrectionsTests.fringed(LensCorrectionsTests.greenFringe)
            let output = LensCorrectionsTests.apply(input, values: ["green_amount": .number(100)])
            for (before, after) in LensCorrectionsTests.fringeRow(input, output) {
                #expect(LensCorrectionsTests.chroma(after) < 0.2 * LensCorrectionsTests.chroma(before), "\(before) → \(after)")
                let ratio = LensCorrectionsTests.luminance(after) / LensCorrectionsTests.luminance(before)
                #expect(abs(ratio - 1) < 2e-3)
            }
        }

        @Test("should remove the fringe from a half-size preview as from the full-size image")
        func preview() {
            let input = LensCorrectionsTests.fringed(LensCorrectionsTests.purpleFringe, band: 3)
            let output = LensCorrectionsTests.apply(input, values: ["purple_amount": .number(100)], scale: 0.5)
            for (before, after) in LensCorrectionsTests.fringeRow(input, output, band: 3) {
                #expect(LensCorrectionsTests.chroma(after) < 0.2 * LensCorrectionsTests.chroma(before), "\(before) → \(after)")
            }
        }

        @Test("should leave pixels far from the edge untouched")
        func local() {
            let input = LensCorrectionsTests.fringed(LensCorrectionsTests.purpleFringe)
            let before = PresencePixels(input)
            let after = PresencePixels(LensCorrectionsTests.apply(input, values: ["purple_amount": .number(100)]))
            for x in [0, 40, 70, 120, 150, 191] {
                #expect(simd_distance(before.rgb(x: x, y: 48), after.rgb(x: x, y: 48)) < 1e-4, "x \(x)")
            }
        }
    }
}
