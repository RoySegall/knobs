import CoreImage
import Foundation
import Testing
@testable import KnobsKit

@Suite("Crop")
struct CropTests {
    static let plugin = CropPlugin()

    static func values(_ stored: [String: KnobValue]) -> KnobValues {
        KnobValues(params: plugin.params, stored: stored)
    }

    static func stored(
        left: Double = 0,
        top: Double = 0,
        right: Double = 1,
        bottom: Double = 1,
        angle: Double = 0,
        aspect: String = "as_shot",
        flipped: Bool = false
    ) -> [String: KnobValue] {
        [
            "left": .number(left), "top": .number(top), "right": .number(right), "bottom": .number(bottom),
            "angle": .number(angle), "aspect": .choice(aspect),
            "flip_horizontal": .flag(flipped), "flip_vertical": .flag(flipped),
        ]
    }

    static func apply(image: CIImage, stored: [String: KnobValue], framing: Framing = .cropped) -> CIImage {
        let context = RenderContext(scale: 1, fullSize: image.extent.size, source: .bitmap, framing: framing)
        return plugin.apply(image: image, values: values(stored), context: context)
    }

    /// Red rises left to right and green bottom to top, so a region's mean says where it came from.
    static func ramp(width: Int, height: Int) -> CIImage {
        var floats = [Float](repeating: 1, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let index = (y * width + x) * 4
                floats[index] = (Float(x) + 0.5) / Float(width)
                floats[index + 1] = (Float(y) + 0.5) / Float(height)
                floats[index + 2] = 0.5
            }
        }
        return TestImages.image(floats: floats, width: width, height: height)
    }

    static func alphas(_ image: CIImage) -> [Float] {
        let floats = Pixels.read(image)
        return stride(from: 3, to: floats.count, by: 4).map { floats[$0] }
    }

    @Suite("apply")
    struct Apply {
        let input = TestImages.detail()

        @Test("should keep at least a pixel when the rect collapses to a line")
        func collapsed() {
            let output = CropTests.apply(image: input, stored: CropTests.stored(left: 1, top: 0.5, right: 1, bottom: 0.5, aspect: "free"))
            #expect(output.extent.width >= 1)
            #expect(output.extent.height >= 1)
            #expect(CropTests.alphas(output).allSatisfy { $0 > 0.999 })
        }

        @Test("should read edges given in the wrong order as the same rect")
        func inverted() {
            let ordered = CropTests.apply(image: input, stored: CropTests.stored(left: 0.2, top: 0.1, right: 0.6, bottom: 0.7, aspect: "free"))
            let swapped = CropTests.apply(image: input, stored: CropTests.stored(left: 0.6, top: 0.7, right: 0.2, bottom: 0.1, aspect: "free"))
            #expect(ordered.extent == swapped.extent)
            #expect(Pixels.maxDifference(between: ordered, and: swapped) == 0)
        }

        @Test("should never leave a transparent pixel when straightened", arguments: [-45.0, -12.5, 0.3, 7, 45])
        func noTransparentCorners(angle: Double) {
            let output = CropTests.apply(image: input, stored: CropTests.stored(angle: angle))
            #expect(output.extent.origin == .zero)
            #expect(CropTests.alphas(output).allSatisfy { $0 > 0.999 }, "angle \(angle)")
        }

        @Test("should slide an off-center crop back onto the photo when straightened")
        func offCenter() {
            let output = CropTests.apply(image: input, stored: CropTests.stored(right: 0.3, bottom: 0.3, angle: 20, aspect: "free"))
            #expect(output.extent.size == CGSize(width: 29, height: 19))
            #expect(CropTests.alphas(output).allSatisfy { $0 > 0.999 })
        }

        @Test("should map the crop rect to the matching source pixels")
        func mapsPixels() {
            let source = CropTests.ramp(width: 96, height: 64)
            let output = CropTests.apply(image: source, stored: CropTests.stored(left: 0.25, top: 0.5, right: 0.75, aspect: "free"))
            // Top 0.5 to bottom 1 is the lower half: Core Image's y runs up from the bottom.
            let expected = source.cropped(to: CGRect(x: 24, y: 0, width: 48, height: 32))
                .transformed(by: CGAffineTransform(translationX: -24, y: 0))
            #expect(output.extent == CGRect(x: 0, y: 0, width: 48, height: 32))
            #expect(Pixels.maxDifference(between: output, and: expected) == 0)
        }

        @Test("should shrink a full-frame crop to the largest rect that fits the rotated photo")
        func largestInscribed() {
            let output = CropTests.apply(image: input, stored: CropTests.stored(angle: 10))
            let c = cos(10 * Double.pi / 180)
            let s = sin(10 * Double.pi / 180)
            let scale = min(96 / (96 * c + 64 * s), 64 / (96 * s + 64 * c))
            #expect(output.extent.size == CGSize(width: (96 * scale).rounded(), height: (64 * scale).rounded()))
        }

        @Test("should fit the aspect ratio inside the requested rect", arguments: [("1:1", CGSize(width: 64, height: 64)), ("16:9", CGSize(width: 96, height: 54)), ("3:2", CGSize(width: 96, height: 64))])
        func aspect(choice: String, size: CGSize) {
            let output = CropTests.apply(image: input, stored: CropTests.stored(aspect: choice))
            #expect(output.extent.size == size)
        }

        @Test("should turn the aspect ratio to follow a portrait crop")
        func portrait() {
            let stored = CropTests.stored(left: 0.25, right: 0.5, aspect: "3:2")
            #expect(CropTests.apply(image: input, stored: stored).extent.size == CGSize(width: 24, height: 36))
        }

        @Test("should mirror the photo when flipped")
        func flips() {
            let output = CropTests.apply(image: input, stored: CropTests.stored(flipped: true))
            let expected = input.transformed(by: CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: 96, ty: 64))
            #expect(output.extent == input.extent)
            #expect(Pixels.maxDifference(between: output, and: expected) == 0)
        }

        @Test("should move the output origin to zero")
        func origin() {
            let shifted = input.transformed(by: CGAffineTransform(translationX: 10, y: -5))
            #expect(CropTests.apply(image: shifted, stored: CropTests.stored(aspect: "1:1")).extent == CGRect(x: 0, y: 0, width: 64, height: 64))
            #expect(CropTests.apply(image: shifted, stored: CropTests.stored(angle: 5)).extent.origin == .zero)
        }

        @Test("should show the whole straightened photo with clear corners when uncropped")
        func uncropped() throws {
            let output = CropTests.apply(image: input, stored: CropTests.stored(angle: 30, aspect: "1:1"), framing: .uncropped)
            let bounds = CropGeometry(size: input.extent.size, angle: 30).boundingSize
            #expect(output.extent == CGRect(x: 0, y: 0, width: bounds.width.rounded(), height: bounds.height.rounded()))
            let alphas = CropTests.alphas(output)
            let width = Int(output.extent.width)
            let height = Int(output.extent.height)
            #expect(alphas[0] == 0)
            #expect(alphas[(height / 2) * width + width / 2] > 0.999)
        }
    }

    @Suite("scale")
    struct Scale {
        @Test("should crop the same part of the photo in the preview as in the export")
        func previewMatchesExport() {
            let full = CropTests.ramp(width: 960, height: 640)
            let photo = Photo(url: URL(fileURLWithPath: "/tmp/ramp.png"), source: .bitmap(full), fullSize: full.extent.size)
            let engine = RenderEngine(plugins: [CropPlugin()])
            var document = EditDocument()
            let stored = CropTests.stored(left: 0.1, top: 0.2, right: 0.7, bottom: 0.9, angle: 8, aspect: "free")
            for (id, value) in stored {
                document.set(value: value, param: CropTests.plugin.param(id)!, plugin: "crop")
            }
            let export = engine.image(photo: photo, document: document, request: RenderRequest())
            let preview = engine.image(photo: photo, document: document, request: RenderRequest(maxPixelSize: 240))

            #expect(abs(preview.extent.width - export.extent.width / 4) <= 1)
            #expect(abs(preview.extent.height - export.extent.height / 4) <= 1)
            let exportMean = Pixels.mean(export)
            let previewMean = Pixels.mean(preview)
            #expect(abs(exportMean.x - previewMean.x) < 0.005)
            #expect(abs(exportMean.y - previewMean.y) < 0.005)
        }
    }

    @Suite("overlay")
    struct Overlay {
        /// The pixel at `point` (Core Image coordinates), bilinear between pixel centers.
        static func sample(image: CIImage, at point: CGPoint) -> SIMD4<Float> {
            let shifted = image.transformed(by: CGAffineTransform(translationX: 0.5 - point.x, y: 0.5 - point.y))
            return Pixels.mean(shifted.cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1)))
        }

        @Test("should draw a crop point over the pixel the crop renders there", arguments: [CGPoint(x: 0.2, y: 0.15), CGPoint(x: 0.47, y: 0.5), CGPoint(x: 0.75, y: 0.8)])
        func linesUp(point: CGPoint) {
            let source = CropTests.ramp(width: 480, height: 320)
            let stored = CropTests.stored(left: 0.15, top: 0.1, right: 0.8, bottom: 0.85, angle: -12, aspect: "free")
            let cropped = CropTests.apply(image: source, stored: stored)
            let uncropped = CropTests.apply(image: source, stored: stored, framing: .uncropped)
            let settings = CropSettings(values: CropTests.values(stored))
            let rect = settings.effectiveRect(size: source.extent.size)

            // Where the crop renders the point: its output is centered on the rect's center.
            let inCrop = CGPoint(
                x: (point.x - rect.midX) * 480 + cropped.extent.width / 2,
                y: (rect.midY - point.y) * 320 + cropped.extent.height / 2
            )
            // Where the overlay draws it: through the bounding box, as a fraction of the uncropped preview.
            let unit = settings.geometry(size: source.extent.size).boundingPoint(point)
            let inPreview = CGPoint(x: unit.x * uncropped.extent.width, y: (1 - unit.y) * uncropped.extent.height)

            let expected = Overlay.sample(image: cropped, at: inCrop)
            let shown = Overlay.sample(image: uncropped, at: inPreview)
            #expect(abs(expected.x - shown.x) < 1.5e-3, "x at \(point)")
            #expect(abs(expected.y - shown.y) < 1.5e-3, "y at \(point)")
        }
    }

    @Suite("CropGeometry")
    struct Geometry {
        let photo = CGSize(width: 150, height: 100)

        func pixels(_ rect: CGRect) -> CGSize {
            CGSize(width: rect.width * photo.width, height: rect.height * photo.height)
        }

        @Test("should never shrink a resize below the minimum side")
        func minimum() {
            let geometry = CropGeometry(size: photo, angle: 0)
            let result = geometry.resized(rect: CGRect(x: 0.2, y: 0.2, width: 0.4, height: 0.4), handle: .right, by: CGVector(dx: -1, dy: 0), ratio: nil)
            #expect(abs(pixels(result).width - CropGeometry.minimumSide * 100) < 1e-9)
            #expect(result.minX == 0.2)
        }

        @Test("should stop a resize at the rotated photo's edge")
        func stopsAtEdge() {
            let geometry = CropGeometry(size: photo, angle: 15)
            let start = CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)
            let result = geometry.resized(rect: start, handle: .bottomRight, by: CGVector(dx: 1, dy: 1), ratio: nil)
            #expect(geometry.contains(rect: result))
            #expect(!geometry.contains(rect: result.insetBy(dx: -0.01, dy: -0.01)))
            #expect(result.minX == start.minX)
            #expect(result.minY == start.minY)
        }

        @Test("should keep the ratio and the opposite corner when resizing with an aspect")
        func keepsRatio() {
            let geometry = CropGeometry(size: photo, angle: 5)
            let start = geometry.effectiveRect(requested: CGRect(x: 0.3, y: 0.3, width: 0.3, height: 0.3), ratio: 1.5)
            let result = geometry.resized(rect: start, handle: .topLeft, by: CGVector(dx: -0.1, dy: -0.02), ratio: 1.5)
            let size = pixels(result)
            #expect(abs(size.width / size.height - 1.5) < 1e-9)
            #expect(abs(result.maxX - start.maxX) < 1e-12)
            #expect(abs(result.maxY - start.maxY) < 1e-12)
            #expect(result.width > start.width)
            #expect(geometry.contains(rect: result))
        }

        @Test("should center an edge drag with an aspect on the other axis")
        func edgeWithRatio() {
            let geometry = CropGeometry(size: photo, angle: 0)
            let start = CGRect(x: 0.3, y: 0.3, width: 0.2, height: 0.3)
            let result = geometry.resized(rect: start, handle: .right, by: CGVector(dx: 0.1, dy: 0), ratio: 1)
            #expect(abs(pixels(result).width - pixels(result).height) < 1e-9)
            #expect(abs(result.midY - start.midY) < 1e-12)
            #expect(result.minX == start.minX)
        }

        @Test("should slide a moved rect along the photo's edge instead of leaving it")
        func slides() {
            let geometry = CropGeometry(size: photo, angle: 0)
            let result = geometry.moved(rect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2), by: CGVector(dx: -0.5, dy: 0.05))
            #expect(abs(result.minX) < 1e-12)
            #expect(abs(result.minY - 0.15) < 1e-12)
            #expect(abs(result.width - 0.2) < 1e-12)

            let tilted = CropGeometry(size: photo, angle: 20)
            let moved = tilted.moved(rect: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2), by: CGVector(dx: 2, dy: -2))
            #expect(tilted.contains(rect: moved))
            #expect(abs(moved.width - 0.2) < 1e-12)
        }

        @Test("should leave a rect that already fits as it is")
        func validUnchanged() {
            let geometry = CropGeometry(size: photo, angle: 0)
            let rect = CGRect(x: 0.2, y: 0.25, width: 0.3, height: 0.4)
            let result = geometry.effectiveRect(requested: rect, ratio: nil)
            #expect(abs(result.minX - rect.minX) < 1e-12 && abs(result.maxY - rect.maxY) < 1e-12)
            #expect(geometry.effectiveRect(requested: CGRect(x: 0, y: 0, width: 1, height: 1), ratio: 1.5) == CGRect(x: 0, y: 0, width: 1, height: 1))
        }

        @Test("should swap the orientation about the center")
        func swaps() {
            let geometry = CropGeometry(size: photo, angle: 0)
            let rect = CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4)
            let result = geometry.swappedOrientation(rect)
            #expect(abs(pixels(result).width - 40) < 1e-9)
            #expect(abs(pixels(result).height - 60) < 1e-9)
            #expect(abs(result.midX - 0.5) < 1e-12 && abs(result.midY - 0.5) < 1e-12)
        }

        @Test("should fill the largest rect of a ratio as near the center as it fits")
        func largest() {
            let geometry = CropGeometry(size: photo, angle: 0)
            let result = geometry.largest(ratio: 1, around: CGPoint(x: 0.2, y: 0.5))
            #expect(abs(result.minX) < 1e-12)
            #expect(abs(pixels(result).width - 100) < 1e-9)
            #expect(abs(pixels(result).height - 100) < 1e-9)
        }

        @Test("should map crop points into the bounding box and back")
        func bounding() {
            let level = CropGeometry(size: photo, angle: 0)
            #expect(level.boundingPoint(CGPoint(x: 0.25, y: 0.75)) == CGPoint(x: 0.25, y: 0.75))

            let tilted = CropGeometry(size: photo, angle: -33)
            let point = CGPoint(x: 0.1, y: 0.8)
            let back = tilted.cropPoint(bounding: tilted.boundingPoint(point))
            #expect(abs(back.x - point.x) < 1e-12 && abs(back.y - point.y) < 1e-12)
            #expect(tilted.boundingPoint(CGPoint(x: 0.5, y: 0.5)) == CGPoint(x: 0.5, y: 0.5))
        }

        @Test("should turn the angle with a drag around the pivot, clockwise positive")
        func straightens() {
            let pivot = CGPoint(x: 100, y: 100)
            let clockwise = CropGeometry.straightened(angle: 2, from: CGPoint(x: 200, y: 100), to: CGPoint(x: 200, y: 110), around: pivot)
            #expect(abs(clockwise - (2 + atan(0.1) * 180 / .pi)) < 1e-9)
            let limited = CropGeometry.straightened(angle: 0, from: CGPoint(x: 200, y: 100), to: CGPoint(x: 100, y: 0), around: pivot)
            #expect(limited == -45)
        }
    }
}
