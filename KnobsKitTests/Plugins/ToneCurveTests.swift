import CoreImage
import Foundation
import Testing
@testable import KnobsKit

@Suite("ToneCurve")
struct ToneCurveTests {
    static func toGamma(_ x: Double) -> Double {
        x <= 0.0031308 ? x * 12.92 : 1.055 * pow(x, 1 / 2.4) - 0.055
    }

    static func toLinear(_ x: Double) -> Double {
        x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
    }

    static func points(_ pairs: [(Double, Double)]) -> [CurvePoint] {
        pairs.map { CurvePoint(x: $0.0, y: $0.1) }
    }

    /// Asserts every segment stays between its two points, sampled densely.
    static func expectNoOvershoot(_ curve: MonotoneCurve) {
        for (start, end) in zip(curve.points, curve.points.dropFirst()) {
            let low = min(start.y, end.y) - 1e-12
            let high = max(start.y, end.y) + 1e-12
            for step in 0...200 {
                let x = start.x + (end.x - start.x) * Double(step) / 200
                let y = curve.value(at: x)
                #expect(y >= low && y <= high, "y(\(x)) = \(y) outside \(low)...\(high)")
            }
        }
    }

    @Suite("MonotoneCurve")
    struct Interpolation {
        @Test("should not overshoot around a steep step")
        func steepStep() {
            let curve = MonotoneCurve(points: ToneCurveTests.points([(0, 0), (0.4, 0.05), (0.5, 0.95), (1, 1)]))
            ToneCurveTests.expectNoOvershoot(curve)
            let ys = (0...1000).map { curve.value(at: Double($0) / 1000) }
            #expect(zip(ys, ys.dropFirst()).allSatisfy { $0 <= $1 })
        }

        @Test("should stay flat between two points at the same height")
        func flat() {
            let curve = MonotoneCurve(points: ToneCurveTests.points([(0, 0), (0.3, 0.5), (0.7, 0.5), (1, 1)]))
            for step in 0...40 {
                #expect(curve.value(at: 0.3 + 0.4 * Double(step) / 40) == 0.5)
            }
        }

        @Test("should keep each segment between its points on a curve that falls and rises")
        func wavy() {
            let curve = MonotoneCurve(points: ToneCurveTests.points([(0, 1), (0.3, 0.2), (0.6, 0.8), (1, 0)]))
            ToneCurveTests.expectNoOvershoot(curve)
        }

        @Test("should survive unsorted, duplicate and non-finite points")
        func messy() {
            let curve = MonotoneCurve(points: ToneCurveTests.points([(1, 1), (0.5, 0.2), (.nan, 0.3), (0, 0), (0.5, 0.6)]))
            #expect(curve.points.map(\.x) == [0, 0.5, 1])
            #expect(curve.value(at: 0.5) == 0.6)
            #expect((0...100).allSatisfy { curve.value(at: Double($0) / 100).isFinite })
        }

        @Test("should hold flat beyond its first and last point")
        func flatEnds() {
            let curve = MonotoneCurve(points: ToneCurveTests.points([(0.2, 0.1), (0.8, 0.9)]))
            #expect(curve.value(at: 0) == 0.1)
            #expect(curve.value(at: 1) == 0.9)
            #expect(curve.slope(at: 0.1) == 0)
        }

        @Test("should pass through every point")
        func passesThrough() {
            let points = ToneCurveTests.points([(0, 0.05), (0.25, 0.18), (0.6, 0.7), (0.75, 0.85), (1, 0.97)])
            let curve = MonotoneCurve(points: points)
            for point in points {
                #expect(abs(curve.value(at: point.x) - point.y) < 1e-12)
            }
            #expect(curve.values(at: points.map(\.x)) == points.map(\.y))
        }

        @Test("should be the straight line through two points")
        func line() {
            let curve = MonotoneCurve(points: CurvePoint.identity)
            #expect(curve.isIdentity)
            for step in 0...10 {
                let x = Double(step) / 10
                #expect(abs(curve.value(at: x) - x) < 1e-12)
                #expect(abs(curve.slope(at: x) - 1) < 1e-12)
            }
        }
    }

    @Suite("ParametricCurve")
    struct Parametric {
        @Test("should keep a positive slope with every slider at either extreme")
        func extremes() {
            let corners = [-100.0, 100]
            for shadows in corners {
                for darks in corners {
                    for lights in corners {
                        for highlights in corners {
                            let curve = ParametricCurve.curve(shadows: shadows, darks: darks, lights: lights, highlights: highlights)
                            let slopes = (0...400).map { curve.slope(at: Double($0) / 400) }
                            #expect(slopes.allSatisfy { $0 > 0.09 }, "\(shadows) \(darks) \(lights) \(highlights)")
                        }
                    }
                }
            }
        }

        @Test("should be the identity with every slider at zero")
        func identity() {
            #expect(ParametricCurve.curve(shadows: 0, darks: 0, lights: 0, highlights: 0).isIdentity)
        }

        @Test("should leave tones beyond the neighbouring region untouched")
        func isolated() {
            let curve = ParametricCurve.curve(shadows: 100, darks: 0, lights: 0, highlights: 0)
            #expect(curve.value(at: 0.125) > 0.125 + 0.07)
            for step in 0...20 {
                let x = 0.375 + 0.625 * Double(step) / 20
                #expect(abs(curve.value(at: x) - x) < 1e-12)
            }
        }
    }

    @Suite("apply")
    struct Apply {
        let plugin = ToneCurvePlugin()

        /// One gray pixel per linear level.
        func strip(_ levels: [Double]) -> CIImage {
            let floats = levels.flatMap { level -> [Float] in [Float(level), Float(level), Float(level), 1] }
            return TestImages.image(floats: floats, width: levels.count, height: 1)
        }

        func apply(_ image: CIImage, _ stored: [String: KnobValue]) -> [Float] {
            let values = KnobValues(params: plugin.params, stored: stored)
            return Pixels.read(plugin.apply(image: image, values: values, context: TestImages.context(for: image)))
        }

        /// Output gray levels in gamma space for input gamma levels.
        func gammaResponse(_ levels: [Double], _ stored: [String: KnobValue], channel: Int = 0) -> [Double] {
            let output = apply(strip(levels.map(ToneCurveTests.toLinear)), stored)
            return levels.indices.map { ToneCurveTests.toGamma(Double(output[$0 * 4 + channel])) }
        }

        @Test("should keep pixels finite beyond white and below black with an inverted curve")
        func invertedOutOfRange() {
            let output = apply(strip([-0.2, 0, 0.5, 1, 4, 60]), ["rgb": .curve(ToneCurveTests.points([(0, 1), (1, 0)]))])
            #expect(output.allSatisfy { $0.isFinite })
            #expect(abs(output[4 * 4]) < 1e-4)
            #expect(abs(output[0] - 1) < 1e-4)
        }

        @Test("should pull sidecar points outside the unit square back in")
        func outsidePoints() {
            let input = TestImages.detail()
            let curve = KnobValue.curve(ToneCurveTests.points([(-0.5, -1), (0.5, 0.5), (1.5, 3)]))
            let values = KnobValues(params: plugin.params, stored: ["rgb": curve])
            let output = plugin.apply(image: input, values: values, context: TestImages.context(for: input))
            #expect(Pixels.maxDifference(between: output, and: input) < 1e-3)
        }

        @Test("should brighten midtones and keep black and white with a lifted midpoint")
        func liftedMidpoint() {
            let response = gammaResponse([0, 0.25, 0.5, 0.75, 1], ["rgb": .curve(ToneCurveTests.points([(0, 0), (0.5, 0.6), (1, 1)]))])
            #expect(abs(response[0]) < 1e-4)
            #expect(abs(response[4] - 1) < 1e-4)
            #expect(abs(response[2] - 0.6) < 1e-3)
            #expect(response[1] > 0.25 && response[3] > 0.75)
        }

        @Test("should match the curve evaluated on the CPU across the whole range")
        func matchesCPU() {
            let points = ToneCurveTests.points([(0, 0.04), (0.25, 0.18), (0.75, 0.85), (1, 0.96)])
            let curve = MonotoneCurve(points: points)
            let levels = (0...64).map { Double($0) / 64 }
            let response = gammaResponse(levels, ["rgb": .curve(points)])
            for (level, output) in zip(levels, response) {
                #expect(abs(output - curve.value(at: level)) < 2e-4, "at \(level)")
            }
        }

        @Test("should leave green and blue alone when only the red curve moves")
        func redOnly() {
            let input = TestImages.detail()
            let before = Pixels.read(input)
            let values = KnobValues(params: plugin.params, stored: ["red": .curve(ToneCurveTests.points([(0, 0), (0.5, 0.7), (1, 1)]))])
            let after = Pixels.read(plugin.apply(image: input, values: values, context: TestImages.context(for: input)))
            var redChange: Float = 0
            for index in stride(from: 0, to: before.count, by: 4) {
                redChange = max(redChange, after[index] - before[index])
                #expect(abs(after[index + 1] - before[index + 1]) < 1e-4)
                #expect(abs(after[index + 2] - before[index + 2]) < 1e-4)
            }
            #expect(redChange > 0.05)
        }

        @Test("should lift darks more than highlights with parametric shadows")
        func parametricShadows() {
            let levels = [0.12, 0.3, 0.7, 0.88]
            let response = gammaResponse(levels, ["shadows": .number(100)])
            let lifts = zip(levels, response).map { $1 - $0 }
            #expect(lifts[0] > 0.05)
            #expect(lifts[0] > lifts[1])
            #expect(abs(lifts[2]) < 1e-3 && abs(lifts[3]) < 1e-3)
        }

        @Test("should carry values beyond white straight through when the top of the curve is untouched")
        func beyondWhite() {
            let output = apply(strip([1.5, 3, 8]), ["shadows": .number(60)])
            #expect(abs(output[0] - 1.5) < 2e-3)
            #expect(abs(output[4] - 3) / 3 < 1e-3)
            #expect(abs(output[8] - 8) / 8 < 1e-3)
        }

        @Test("should compress values beyond white along a flattened top")
        func compressedHighlights() {
            let output = apply(strip([1, 2]), ["rgb": .curve(ToneCurveTests.points([(0, 0), (0.7, 0.9), (1, 1)]))])
            #expect(abs(output[0] - 1) < 1e-3)
            #expect(output[4] > 1 && output[4] < 1.5)
        }
    }
}
