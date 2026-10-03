import CoreImage
import Foundation
import Testing
@testable import KnobsKit

private enum Fixture {
    static func apply(_ image: CIImage, _ stored: [String: Double], scale: Double = 1) -> CIImage {
        let plugin = GrainPlugin()
        let values = KnobValues(params: plugin.params, stored: stored.mapValues { .number($0) })
        let context = RenderContext(scale: scale, fullSize: image.extent.size, source: .bitmap)
        return plugin.apply(image: image, values: values, context: context)
    }

    static func statistics(_ floats: [Float]) -> (mean: Float, deviation: Float) {
        let reds = stride(from: 0, to: floats.count, by: 4).map { floats[$0] }
        return statistics(values: reds)
    }

    static func statistics(values reds: [Float]) -> (mean: Float, deviation: Float) {
        let mean = reds.reduce(0, +) / Float(reds.count)
        let variance = reds.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Float(reds.count)
        return (mean, variance.squareRoot())
    }

    /// Correlation between each pixel and its right-hand neighbor: higher means bigger grains.
    static func neighborCorrelation(_ image: CIImage) -> Float {
        let floats = Pixels.read(image)
        let width = Int(image.extent.width)
        let mean = statistics(floats).mean
        var product: Float = 0
        var square: Float = 0
        for index in stride(from: 0, to: floats.count - 4, by: 4) where (index / 4) % width != width - 1 {
            product += (floats[index] - mean) * (floats[index + 4] - mean)
            square += (floats[index] - mean) * (floats[index] - mean)
        }
        return product / square
    }
}

@Suite("GrainPlugin")
struct GrainTests {
    @Suite("apply")
    struct Apply {
        @Test("should leave the image untouched at zero amount when size and roughness moved")
        func amountZero() {
            let input = TestImages.gray(level: 0.2, size: 32)
            let output = Fixture.apply(input, ["size": 80, "roughness": 10])
            #expect(Pixels.maxDifference(between: output, and: input) == 0)
        }

        @Test("should render the same grain every time")
        func deterministic() {
            let input = TestImages.gray(level: 0.2, size: 64)
            let first = Pixels.read(Fixture.apply(input, ["amount": 60]))
            let second = Pixels.read(Fixture.apply(input, ["amount": 60]))
            #expect(first == second)
        }

        @Test("should never repeat the same patch across the frame")
        func noRepeats() {
            let input = TestImages.gray(level: 0.2, size: 256)
            let output = Fixture.apply(input, ["amount": 60])
            let first = Pixels.read(output.cropped(to: CGRect(x: 0, y: 0, width: 32, height: 32)))
            let shifted = output.cropped(to: CGRect(x: 128, y: 64, width: 32, height: 32))
                .transformed(by: CGAffineTransform(translationX: -128, y: -64))
            #expect(first != Pixels.read(shifted))
        }

        @Test("should add zero-mean grain that is strongest in the midtones")
        func midtones() {
            // Measured in sRGB-encoded values, where equal steps look equal.
            func grain(level: Float) -> (mean: Float, deviation: Float) {
                let floats = Pixels.read(Fixture.apply(TestImages.gray(level: level, size: 128), ["amount": 50]))
                let encoded = stride(from: 0, to: floats.count, by: 4).map { index -> Float in
                    let value = floats[index]
                    return value <= 0.0031308 ? value * 12.92 : 1.055 * pow(value, 1 / 2.4) - 0.055
                }
                return Fixture.statistics(values: encoded)
            }
            let mid = grain(level: 0.2)
            let dark = grain(level: 0.002)
            let bright = grain(level: 0.95)
            #expect(abs(mid.mean - 0.485) < 0.01)
            #expect(mid.deviation > 0.02)
            #expect(dark.deviation < mid.deviation * 0.35)
            #expect(bright.deviation < mid.deviation * 0.5)
        }

        @Test("should grow coarser with size")
        func size() {
            let input = TestImages.gray(level: 0.2, size: 128)
            let fine = Fixture.neighborCorrelation(Fixture.apply(input, ["amount": 50, "size": 0, "roughness": 0]))
            let coarse = Fixture.neighborCorrelation(Fixture.apply(input, ["amount": 50, "size": 100, "roughness": 0]))
            #expect(coarse > fine + 0.3)
        }
    }

    @Suite("preview")
    struct Preview {
        @Test("should keep the downscaled export's grain strength in a downscaled preview", arguments: [0.5, 0.25])
        func matchesDownscaledExport(scale: Double) {
            let size = 512
            let image = TestImages.gray(level: 0.2, size: size)
            let photo = Photo(url: URL(fileURLWithPath: "/tmp/gray.png"), source: .bitmap(image), fullSize: image.extent.size)
            let engine = RenderEngine(plugins: [GrainPlugin()])
            var document = EditDocument()
            document.set(value: .number(60), param: GrainPlugin().param("amount")!, plugin: "grain")

            let export = engine.downscale(engine.image(photo: photo, document: document, request: RenderRequest()), scale: scale)
            let preview = engine.image(photo: photo, document: document, request: RenderRequest(maxPixelSize: Int(Double(size) * scale)))
            let inner = preview.extent.insetBy(dx: 8, dy: 8)
            let exportGrain = Fixture.statistics(Pixels.read(export.cropped(to: inner))).deviation
            let previewGrain = Fixture.statistics(Pixels.read(preview.cropped(to: inner))).deviation
            #expect(previewGrain > exportGrain * 0.8)
            #expect(previewGrain < exportGrain * 1.25)
        }
    }
}
