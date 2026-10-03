import CoreImage
import Foundation
import Testing
@testable import KnobsKit

@Suite("Profile")
struct ProfileTests {
    static let plugin = ProfilePlugin()

    static func values(_ stored: [String: KnobValue] = [:]) -> KnobValues {
        KnobValues(params: plugin.params, stored: stored)
    }

    static func rawContext(for image: CIImage, look: CameraLook? = known) -> RenderContext {
        RenderContext(scale: 1, fullSize: image.extent.size, source: .raw, analysis: PhotoAnalysis(clipLevel: 4, cameraLook: look))
    }

    /// A camera-like rendering: a stop darker through the midtones, a shoulder into white, and 15% more saturation.
    static let known: CameraLook = {
        let pairs = stride(from: Float(-10), through: 0.5, by: 0.25).map { stop -> (Float, Float) in
            let x = exp2(stop)
            return (x, 0.5 * x / (1 + 0.35 * x))
        }
        let levels = CameraLook.levels(pairs: pairs, white: 4)!
        let saturation: Float = 1.15
        let (y0, y1, y2) = CameraLook.lumaWeights
        let matrix: [Float] = [
            saturation + (1 - saturation) * y0, (1 - saturation) * y1, (1 - saturation) * y2,
            (1 - saturation) * y0, saturation + (1 - saturation) * y1, (1 - saturation) * y2,
            (1 - saturation) * y0, (1 - saturation) * y1, saturation + (1 - saturation) * y2,
        ]
        return CameraLook(levels: levels, matrix: matrix, origin: .preview)
    }()

    /// A smooth scene: brightness climbs ten stops bottom to top past white, hue sweeps left to right, with
    /// a band of grays. RGBA floats, linear.
    static func scene(width: Int, height: Int) -> [Float] {
        var floats = [Float](repeating: 1, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let level = exp2(-8.5 + 10.5 * Float(y) / Float(height - 1))
                let hue = Float(x) / Float(width) * 2 * .pi
                let saturation: Float = x % 40 < 8 ? 0 : 0.35
                let index = (y * width + x) * 4
                floats[index] = level * (1 + saturation * cos(hue))
                floats[index + 1] = level * (1 + saturation * cos(hue - 2.094))
                floats[index + 2] = level * (1 + saturation * cos(hue + 2.094))
            }
        }
        return floats
    }

    /// The look applied on the CPU, clipped and rounded to 8-bit sRGB like a camera JPEG.
    static func cameraJPEG(_ pixels: [Float], look: CameraLook) -> [Float] {
        var output = pixels
        let table = ToneTable(look: look)
        look.matrix.withUnsafeBufferPointer { matrix in
            table.read { tone in
                for index in stride(from: 0, to: pixels.count, by: 4) {
                    let (r, g, b) = tone.render(red: pixels[index], green: pixels[index + 1], blue: pixels[index + 2], matrix: matrix)
                    for (offset, value) in [r, g, b].enumerated() {
                        let encoded = (CameraLook.gamma(min(max(value, 0), 1)) * 255).rounded() / 255
                        output[index + offset] = CameraLook.linear(encoded)
                    }
                }
            }
        }
        return output
    }

    /// Largest gap between two curves, in sRGB gamma, where the camera's output is neither crushed nor clipped.
    static func curveGap(_ fitted: CameraLook, _ truth: CameraLook) -> Float {
        let fittedTable = ToneTable(look: fitted)
        let truthTable = ToneTable(look: truth)
        return stride(from: Float(-8), through: 1.5, by: 0.05).map { stop -> Float in
            let x = exp2(stop)
            let expected = truthTable(x)
            guard expected > 0.01, expected < 0.85 else { return 0 }
            return abs(CameraLook.gamma(fittedTable(x)) - CameraLook.gamma(expected))
        }.max() ?? 0
    }

    static func expectRising(_ look: CameraLook) {
        let table = ToneTable(look: look)
        let outputs = stride(from: Float(-14), through: 5, by: 0.01).map { table(exp2($0)) }
        #expect(zip(outputs, outputs.dropFirst()).allSatisfy { $0 <= $1 })
        #expect(zip(look.levels, look.levels.dropFirst()).allSatisfy { $0 < $1 || $0 == 1 })
        #expect(table(0) == 0)
        #expect(table(1e-9) < 1e-8)
        #expect((outputs.last ?? 0) <= 1)
    }

    @Suite("apply")
    struct Apply {
        @Test("should leave a bitmap untouched, since the camera already rendered it")
        func bitmap() {
            let input = TestImages.detail()
            let context = TestImages.context(for: input)
            let output = ProfileTests.plugin.apply(image: input, values: ProfileTests.values(), context: context)
            #expect(Pixels.maxDifference(between: output, and: input) == 0)
            #expect(!ProfileTests.plugin.rendersDisplay(values: ProfileTests.values(), context: context))
        }

        @Test("should leave a RAW untouched with the neutral look or no amount", arguments: [
            ["look": KnobValue.choice("neutral")],
            ["amount": KnobValue.number(0)],
        ])
        func neutral(stored: [String: KnobValue]) {
            let input = TestImages.detail()
            let context = ProfileTests.rawContext(for: input)
            let values = ProfileTests.values(stored)
            let output = ProfileTests.plugin.apply(image: input, values: values, context: context)
            #expect(Pixels.maxDifference(between: output, and: input) == 0)
            #expect(!ProfileTests.plugin.rendersDisplay(values: values, context: context))
        }

        @Test("should keep pixels finite far past white and below black")
        func extremes() {
            let input = TestImages.detail().applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 300, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: -2, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            ])
            let output = ProfileTests.plugin.apply(image: input, values: ProfileTests.values(), context: ProfileTests.rawContext(for: input))
            #expect(Pixels.read(output).allSatisfy { $0.isFinite })
            #expect(output.extent == input.extent)
        }

        @Test("should fall back to the fixed look on a RAW measured without one")
        func unmeasured() {
            let input = TestImages.detail()
            let context = ProfileTests.rawContext(for: input, look: nil)
            #expect(ProfileTests.plugin.look(values: ProfileTests.values(), context: context) == CameraLook.fallback)
        }

        @Test("should match its CPU twin on the GPU")
        func matchesTwin() {
            let input = TestImages.detail()
            let output = Pixels.read(ProfileTests.plugin.apply(image: input, values: ProfileTests.values(), context: ProfileTests.rawContext(for: input)))
            let source = Pixels.read(input)
            var largest: Float = 0
            let table = ToneTable(look: ProfileTests.known)
            ProfileTests.known.matrix.withUnsafeBufferPointer { matrix in
                table.read { tone in
                    for index in stride(from: 0, to: source.count, by: 4) {
                        let (r, g, b) = tone.render(red: source[index], green: source[index + 1], blue: source[index + 2], matrix: matrix)
                        largest = max(largest, abs(output[index] - r), abs(output[index + 1] - g), abs(output[index + 2] - b))
                    }
                }
            }
            #expect(largest < 2e-3)
        }

        @Test("should move from neutral toward the camera look with the amount")
        func amount() {
            let input = TestImages.withinWhite()
            let context = ProfileTests.rawContext(for: input)
            let full = Pixels.mean(ProfileTests.plugin.apply(image: input, values: ProfileTests.values(), context: context))
            let half = Pixels.mean(ProfileTests.plugin.apply(image: input, values: ProfileTests.values(["amount": .number(50)]), context: context))
            let neutral = Pixels.mean(RenderEngine(plugins: []).display(input, source: .raw))
            #expect(full.y < half.y && half.y < neutral.y)
        }
    }

    @Suite("RenderEngine.process")
    struct Engine {
        @Test("should hand the roll-off to the camera look instead of compressing twice")
        func handOff() {
            let input = TestImages.detail()
            let engine = RenderEngine(plugins: [ProfilePlugin()])
            let context = ProfileTests.rawContext(for: input)
            let active = engine.active(document: EditDocument(), skipping: [])
            let rendered = engine.process(image: input, plugins: active, context: context)
            let direct = ProfileTests.plugin.apply(image: input, values: ProfileTests.values(), context: context)
            #expect(Pixels.maxDifference(between: rendered, and: direct) < 2e-3)
        }

        @Test("should roll highlights off as before with the neutral look")
        func neutral() {
            let input = TestImages.detail()
            let engine = RenderEngine(plugins: [ProfilePlugin()])
            var document = EditDocument()
            document.set(value: .choice("neutral"), param: ProfileTests.plugin.params[0], plugin: "profile")
            let active = engine.active(document: document, skipping: [])
            let rendered = engine.process(image: input, plugins: active, context: ProfileTests.rawContext(for: input))
            #expect(Pixels.maxDifference(between: rendered, and: engine.display(input, source: .raw)) == 0)
        }
    }

    @Suite("fit")
    struct Fit {
        @Test("should refuse a sample that spans less than two stops")
        func narrow() {
            let gray = [Float](repeating: 0.2, count: 64 * 64 * 4)
            #expect(CameraLook.fit(ours: gray, camera: gray, clipLevel: 4) == nil)
        }

        @Test("should refuse a preview too small to fit")
        func tinyPreview() {
            let decode = TestImages.image(floats: ProfileTests.scene(width: 300, height: 200), width: 300, height: 200)
            let preview = TestImages.gray(level: 0.3, size: 40)
            #expect(CameraLook.measure(decode: decode, preview: preview, clipLevel: 4, context: Pixels.context) == nil)
        }

        @Test("should fall back to the fixed look when the file has no preview")
        func noPreview() {
            let decode = TestImages.image(floats: ProfileTests.scene(width: 300, height: 200), width: 300, height: 200)
            let look = CameraLook.measure(decode: decode, data: Data("not a raw".utf8), typeIdentifier: "com.sony.arw-raw-image", clipLevel: 4, context: Pixels.context)
            #expect(look == CameraLook.fallback)
            #expect(look.origin == .fallback)
        }

        @Test("should measure no camera look for a bitmap")
        func bitmap() {
            let image = TestImages.gray(level: 0.5)
            #expect(PhotoAnalysis.measure(source: .bitmap(image), fullSize: image.extent.size).cameraLook == nil)
        }

        @Test("should keep the fallback rising from black to white")
        func fallback() {
            ProfileTests.expectRising(CameraLook.fallback)
            #expect(CameraLook.fallback.matrix == CameraLook.identityMatrix)
        }

        @Test("should recover a known curve and color from a JPEG-like camera rendering")
        func recovers() throws {
            let ours = ProfileTests.scene(width: 160, height: 96)
            let camera = ProfileTests.cameraJPEG(ours, look: ProfileTests.known)
            let look = try #require(CameraLook.fit(ours: ours, camera: camera, clipLevel: 4))
            ProfileTests.expectRising(look)
            #expect(look.origin == .preview)
            #expect(ProfileTests.curveGap(look, ProfileTests.known) < 0.02)
            // The fitted matrix boosts saturation like the camera's: each channel gains on its own diagonal.
            #expect(look.matrix[0] > 1.03 && look.matrix[4] > 1.03 && look.matrix[8] > 1.03)
            #expect(look.matrix[1] < 0 && look.matrix[3] < 0)
        }

        @Test("should recover the curve from a preview of the decode's center at another aspect")
        func otherAspect() throws {
            let width = 300
            let height = 200
            let decode = TestImages.image(floats: ProfileTests.scene(width: width, height: height), width: width, height: height)
            let center = CameraLook.centered(in: decode.extent, aspect: 16.0 / 9.0)
            let previewPixels = Pixels.read(CameraLook.resampled(decode, from: center, to: CGSize(width: 256, height: 144)))
            let rendered = ProfileTests.cameraJPEG(previewPixels, look: ProfileTests.known)
            let preview = TestImages.image(floats: rendered, width: 256, height: 144)
            let look = try #require(CameraLook.measure(decode: decode, preview: preview, clipLevel: 4, context: Pixels.context))
            #expect(ProfileTests.curveGap(look, ProfileTests.known) < 0.03)
        }

        @Test("should trim black letterbox bars evenly")
        func bars() {
            var floats = ProfileTests.scene(width: 120, height: 90)
            for index in stride(from: 0, to: floats.count, by: 4) where index / 4 / 120 < 8 || index / 4 / 120 >= 80 {
                floats[index] = 0
                floats[index + 1] = 0
                floats[index + 2] = 0
            }
            let preview = TestImages.image(floats: floats, width: 120, height: 90)
            #expect(CameraLook.withoutBars(preview, context: Pixels.context) == CGRect(x: 0, y: 8, width: 120, height: 74))
        }
    }
}
