import CoreImage
import Foundation
import Testing
@testable import KnobsKit

private enum Fixture {
    static let size = 64

    /// A dark-to-bright step softened like a lens would, running left to right.
    static func softEdge() -> CIImage {
        image { x, _ in
            let t = 1 / (1 + exp(-(Float(x) - 31.5) / 0.7))
            return SIMD3(repeating: linear(0.25 + 0.5 * t))
        }
    }

    /// Mid-gray with faint seeded luma noise, like a clean sky.
    static func flatNoisy() -> CIImage {
        var random = SplitMix(seed: 7)
        return image { _, _ in SIMD3(repeating: linear(0.5 + 0.004 * random.gaussian())) }
    }

    /// The soft edge in orange over blue, to check that sharpening leaves color alone.
    static func colorEdge() -> CIImage {
        image { x, _ in
            let t = 1 / (1 + exp(-(Float(x) - 31.5) / 1.2))
            return SIMD3(linear(0.2 + 0.6 * t), linear(0.25 + 0.3 * t), linear(0.6 - 0.4 * t))
        }
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

    static func linear(_ value: Float) -> Float {
        value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }

    static func gamma(_ value: Float) -> Float {
        value <= 0.0031308 ? value * 12.92 : 1.055 * pow(value, 1 / 2.4) - 0.055
    }

    /// sRGB-encoded channels along the middle row.
    static func row(_ image: CIImage) -> [SIMD3<Float>] {
        let floats = Pixels.read(image)
        return (0..<size).map { x in
            let index = (32 * size + x) * 4
            return SIMD3(gamma(floats[index]), gamma(floats[index + 1]), gamma(floats[index + 2]))
        }
    }

    static func apply(_ image: CIImage, _ stored: [String: Double]) -> CIImage {
        let plugin = SharpeningPlugin()
        let values = KnobValues(params: plugin.params, stored: stored.mapValues { .number($0) })
        return plugin.apply(image: image, values: values, context: TestImages.context(for: image))
    }
}

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

@Suite("SharpeningPlugin")
struct SharpeningTests {
    @Suite("apply")
    struct Apply {
        @Test("should leave the image untouched when only radius, detail or masking moved")
        func amountZero() {
            let input = Fixture.softEdge()
            let output = Fixture.apply(input, ["radius": 2.5, "detail": 80, "masking": 40])
            #expect(Pixels.maxDifference(between: output, and: input) == 0)
        }

        @Test("should leave a flat noisy area untouched at masking 100")
        func maskingSparesFlatAreas() {
            let input = Fixture.flatNoisy()
            let output = Fixture.apply(input, ["amount": 150, "masking": 100])
            #expect(Pixels.maxDifference(between: output, and: input) < 1e-4)
        }

        @Test("should keep halos inside the edge's own range at detail 0")
        func suppressesHalos() {
            let input = Fixture.row(Fixture.softEdge())
            let suppressed = Fixture.row(Fixture.apply(Fixture.softEdge(), ["amount": 150, "radius": 2, "detail": 0]))
            let classic = Fixture.row(Fixture.apply(Fixture.softEdge(), ["amount": 150, "radius": 2, "detail": 100]))
            let low = input.map(\.x).min()!
            let high = input.map(\.x).max()!
            #expect(suppressed.map(\.x).min()! > low - 0.005)
            #expect(suppressed.map(\.x).max()! < high + 0.005)
            #expect(classic.map(\.x).max()! > high + 0.03)
        }

        @Test("should sharpen texture less at a low detail than at a high one")
        func detailSharpensTexture() {
            let input = Fixture.flatNoisy()
            let low = Pixels.maxDifference(between: Fixture.apply(input, ["amount": 100, "detail": 0]), and: input)
            let high = Pixels.maxDifference(between: Fixture.apply(input, ["amount": 100, "detail": 100]), and: input)
            #expect(high > low * 2)
        }

        @Test("should raise contrast across a soft edge")
        func raisesEdgeContrast() {
            let before = Fixture.row(Fixture.softEdge())
            let after = Fixture.row(Fixture.apply(Fixture.softEdge(), ["amount": 100]))
            let contrastBefore = before[33].x - before[30].x
            let contrastAfter = after[33].x - after[30].x
            #expect(contrastAfter > contrastBefore * 1.1, "\(contrastBefore) \(contrastAfter)")
        }

        @Test("should sharpen luma only and keep each pixel's color differences")
        func lumaOnly() {
            let before = Fixture.row(Fixture.colorEdge())
            let after = Fixture.row(Fixture.apply(Fixture.colorEdge(), ["amount": 150, "detail": 100]))
            for x in 24..<40 {
                let shiftBefore = SIMD2(before[x].x - before[x].y, before[x].z - before[x].y)
                let shiftAfter = SIMD2(after[x].x - after[x].y, after[x].z - after[x].y)
                #expect(abs(shiftBefore.x - shiftAfter.x) < 2e-3, "x = \(x)")
                #expect(abs(shiftBefore.y - shiftAfter.y) < 2e-3, "x = \(x)")
            }
        }
    }

    @Suite("preview")
    struct Preview {
        @Test("should look in a quarter-size preview about as strong as the export does once downscaled")
        func matchesDownscaledExport() {
            var random = SplitMix(seed: 3)
            let size = 512
            var floats = [Float](repeating: 1, count: size * size * 4)
            // Value noise at 2 to 32 px with amplitude rising with scale: the 1/f spectrum of a natural photo.
            let spacings = [2, 4, 8, 16, 32]
            let grids = spacings.map { spacing in (0..<((size / spacing + 2) * (size / spacing + 2))).map { _ in random.uniform() - 0.5 } }
            func smooth(_ t: Float) -> Float { t * t * (3 - 2 * t) }
            for y in 0..<size {
                for x in 0..<size {
                    var value: Float = 0.45
                    for (spacing, grid) in zip(spacings, grids) {
                        let cells = size / spacing + 2
                        let fx = Float(x) / Float(spacing), fy = Float(y) / Float(spacing)
                        let cx = Int(fx), cy = Int(fy)
                        let tx = smooth(fx - Float(cx)), ty = smooth(fy - Float(cy))
                        let top = grid[cy * cells + cx] * (1 - tx) + grid[cy * cells + cx + 1] * tx
                        let bottom = grid[(cy + 1) * cells + cx] * (1 - tx) + grid[(cy + 1) * cells + cx + 1] * tx
                        value += 0.04 * Float(spacing).squareRoot() * (top * (1 - ty) + bottom * ty)
                    }
                    let index = (y * size + x) * 4
                    floats[index] = Fixture.linear(value)
                    floats[index + 1] = Fixture.linear(value)
                    floats[index + 2] = Fixture.linear(value)
                }
            }
            let image = TestImages.image(floats: floats, width: size, height: size)
            let photo = Photo(url: URL(fileURLWithPath: "/tmp/texture.png"), source: .bitmap(image), fullSize: image.extent.size)
            let engine = RenderEngine(plugins: [SharpeningPlugin()])
            var document = EditDocument()
            document.set(value: .number(100), param: SharpeningPlugin().param("amount")!, plugin: "sharpening")

            let export = engine.image(photo: photo, document: document, request: RenderRequest())
            let downscaledExport = engine.downscale(export, scale: 0.25)
            let downscaledOriginal = engine.downscale(image, scale: 0.25)
            let preview = engine.image(photo: photo, document: document, request: RenderRequest(maxPixelSize: size / 4))
            let exportChange = rms(Pixels.read(downscaledExport), Pixels.read(downscaledOriginal))
            let previewChange = rms(Pixels.read(preview), Pixels.read(downscaledOriginal))
            #expect(previewChange > exportChange * 0.6)
            #expect(previewChange < exportChange * 1.6, "\(previewChange) \(exportChange)")
        }

        private func rms(_ first: [Float], _ second: [Float]) -> Float {
            let sum = zip(first, second).reduce(Float(0)) { $0 + ($1.0 - $1.1) * ($1.0 - $1.1) }
            return (sum / Float(first.count)).squareRoot()
        }
    }
}
