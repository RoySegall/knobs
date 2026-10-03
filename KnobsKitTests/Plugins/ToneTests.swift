import CoreImage
import Foundation
import Testing
@testable import KnobsKit

@Suite("TonePlugin")
struct ToneTests {
    /// Runs an image through the plugin with the given slider values.
    static func applied(image: CIImage, values stored: [String: Double]) -> CIImage {
        let plugin = TonePlugin()
        let values = KnobValues(params: plugin.params, stored: stored.mapValues { .number($0) })
        return plugin.apply(image: image, values: values, context: TestImages.context(for: image))
    }

    /// A row of colors, `height` rows tall, so a base layer has room to form.
    static func row(colors: [SIMD3<Float>], height: Int = 1) -> CIImage {
        let line: [Float] = colors.flatMap { [$0.x, $0.y, $0.z, 1] }
        let floats = (0..<height).flatMap { _ in line }
        return TestImages.image(floats: floats, width: colors.count, height: height)
    }

    /// The middle row's colors.
    static func middleRow(_ image: CIImage) -> [SIMD3<Float>] {
        let pixels = Pixels.read(image)
        let width = Int(image.extent.width)
        let start = Int(image.extent.height) / 2 * width * 4
        return (0..<width).map { SIMD3(pixels[start + $0 * 4], pixels[start + $0 * 4 + 1], pixels[start + $0 * 4 + 2]) }
    }

    static func gray(_ level: Float) -> SIMD3<Float> {
        SIMD3(repeating: level)
    }

    static func stops(from before: SIMD3<Float>, to after: SIMD3<Float>) -> Float {
        log2(after.y / before.y)
    }

    /// Dark on the left half, bright on the right: the edge every local tone tool has to respect.
    static func step(dark: Float, bright: Float) -> CIImage {
        row(colors: (0..<400).map { gray($0 < 200 ? dark : bright) }, height: 8)
    }

    @Suite("whites and blacks")
    struct Ends {
        @Test("should never brighten a displayed channel when crushing a dark out-of-gamut color")
        func crushedOutOfGamut() {
            let color = SIMD3<Float>(0.05, -0.002, -0.003)
            let output = ToneTests.middleRow(ToneTests.applied(image: ToneTests.row(colors: [color]), values: ["blacks": -100]))[0]
            #expect(output.x <= color.x)
            #expect(max(output.y, 0) <= max(color.y, 0))
            #expect(max(output.z, 0) <= max(color.z, 0))
        }

        @Test("should stay monotonic from black to well past white", arguments: ["whites", "blacks"], [-100.0, 100.0])
        func monotonic(param: String, value: Double) {
            let ramp = (0..<64).map { ToneTests.gray(Float($0) / 40) }
            let output = ToneTests.middleRow(ToneTests.applied(image: ToneTests.row(colors: ramp), values: [param: value]))
            for index in 1..<output.count {
                #expect(output[index].x >= output[index - 1].x)
                #expect(output[index].x.isFinite)
            }
        }

        @Test("should hold mid-gray nearly still", arguments: ["whites", "blacks"], [-100.0, 100.0])
        func midGray(param: String, value: Double) {
            let output = ToneTests.middleRow(ToneTests.applied(image: ToneTests.row(colors: [ToneTests.gray(0.18)]), values: [param: value]))[0]
            #expect(abs(output.x - 0.18) < 0.18 * 0.03)
        }

        @Test("should clip near-white to white with plus whites and pull white down with minus")
        func whites() {
            let levels = [0.8, 1, 2].map(ToneTests.gray)
            let plus = ToneTests.middleRow(ToneTests.applied(image: ToneTests.row(colors: levels), values: ["whites": 100]))
            let minus = ToneTests.middleRow(ToneTests.applied(image: ToneTests.row(colors: levels), values: ["whites": -100]))
            #expect(plus[0].x > 1)
            #expect(minus[1].x < 0.7)
            #expect(minus[2].x < 1)
        }

        @Test("should clip deep shadows to black with minus blacks and lift black with plus")
        func blacks() {
            let levels = [0, 0.005].map(ToneTests.gray)
            let minus = ToneTests.middleRow(ToneTests.applied(image: ToneTests.row(colors: levels), values: ["blacks": -100]))
            let plus = ToneTests.middleRow(ToneTests.applied(image: ToneTests.row(colors: levels), values: ["blacks": 100]))
            #expect(minus[1].x == 0)
            #expect(plus[0].x > 0.01)
        }
    }

    @Suite("highlights and shadows")
    struct Local {
        @Test("should not halo across a hard edge")
        func noHalo() {
            let input = ToneTests.step(dark: 0.01, bright: 0.9)
            let before = ToneTests.middleRow(input)
            let after = ToneTests.middleRow(ToneTests.applied(image: input, values: ["highlights": -100, "shadows": 100]))
            let gains = zip(before, after).map { ToneTests.stops(from: $0, to: $1) }
            for x in 0..<200 {
                #expect(abs(gains[x] - gains[0]) < 0.05, "dark side x=\(x): \(gains[x]) vs \(gains[0])")
            }
            for x in 200..<400 {
                #expect(abs(gains[x] - gains[399]) < 0.05, "bright side x=\(x): \(gains[x]) vs \(gains[399])")
            }
        }

        @Test("should stay monotonic along a smooth ramp", arguments: ["highlights", "shadows"], [-100.0, 100.0])
        func monotonic(param: String, value: Double) {
            let ramp = (0..<256).map { ToneTests.gray(0.002 * pow(1000, Float($0) / 255)) }
            let output = ToneTests.middleRow(ToneTests.applied(image: ToneTests.row(colors: ramp, height: 4), values: [param: value]))
            for index in 1..<output.count {
                #expect(output[index].y > output[index - 1].y, "\(param) \(value) at \(index)")
            }
        }

        @Test("should recover bright regions with minus highlights and leave dark regions alone")
        func recoversHighlights() {
            let input = ToneTests.step(dark: 0.02, bright: 0.8)
            let before = ToneTests.middleRow(input)
            let after = ToneTests.middleRow(ToneTests.applied(image: input, values: ["highlights": -100]))
            #expect(ToneTests.stops(from: before[399], to: after[399]) < -0.5)
            #expect(abs(ToneTests.stops(from: before[0], to: after[0])) < 0.02)
        }

        @Test("should bring regions above white back under it with minus highlights")
        func overWhite() {
            let output = ToneTests.middleRow(ToneTests.applied(image: ToneTests.row(colors: [ToneTests.gray(2)], height: 4), values: ["highlights": -100]))[0]
            #expect(output.y < 1)
        }

        @Test("should brighten bright regions with plus highlights")
        func brightensHighlights() {
            let output = ToneTests.middleRow(ToneTests.applied(image: ToneTests.row(colors: [ToneTests.gray(0.6)], height: 4), values: ["highlights": 100]))[0]
            #expect(output.y > 0.7)
        }

        @Test("should open dark regions with plus shadows and leave bright regions alone")
        func opensShadows() {
            let input = ToneTests.step(dark: 0.02, bright: 0.8)
            let before = ToneTests.middleRow(input)
            let after = ToneTests.middleRow(ToneTests.applied(image: input, values: ["shadows": 100]))
            #expect(ToneTests.stops(from: before[0], to: after[0]) > 1)
            #expect(abs(ToneTests.stops(from: before[399], to: after[399])) < 0.05)
        }

        @Test("should deepen dark regions with minus shadows but keep black at zero")
        func deepensShadows() {
            let output = ToneTests.middleRow(ToneTests.applied(image: ToneTests.row(colors: [0.02, 0].map(ToneTests.gray), height: 4), values: ["shadows": -100]))
            #expect(output[0].y < 0.01)
            #expect(output[1].y == 0)
        }

        @Test("should keep fine texture inside a recovered highlight")
        func keepsTexture() {
            // A 2 px checker between 0.6 and 0.9: a global curve would squeeze the 1.5x ratio to about 1.1.
            let width = 512
            let height = 64
            var floats = [Float]()
            for y in 0..<height {
                for x in 0..<width {
                    let level: Float = (x / 2 + y / 2) % 2 == 0 ? 0.9 : 0.6
                    floats += [level, level, level, 1]
                }
            }
            let input = TestImages.image(floats: floats, width: width, height: height)
            let row = ToneTests.middleRow(ToneTests.applied(image: input, values: ["highlights": -100]))
            let center = width / 2
            let ratio = max(row[center].y, row[center + 2].y) / min(row[center].y, row[center + 2].y)
            #expect(ratio > 1.35)
            #expect(max(row[center].y, row[center + 2].y) < 0.8)
        }
    }
}
