import CoreImage
import Foundation
import Testing
@testable import KnobsKit

@Suite("AutoTone")
struct AutoToneTests {
    static let engine = RenderEngine()

    /// A photo-like scene: soft overlapping waves of tone around mid-gray, so most pixels sit in the
    /// midtones and a few touch black and white, in muted to vivid hues. `tone` maps its sRGB-encoded values.
    static func scene(tone: (Double) -> Double = { $0 }) -> Photo {
        let width = 160
        let height = 120
        var floats = [Float](repeating: 1, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let u = Double(x) / Double(width)
                let v = Double(y) / Double(height)
                let wave = 0.28 * sin(2 * .pi * (u * 1.3 + v * 0.4)) + 0.18 * sin(2 * .pi * v * 1.7) + 0.1 * sin(2 * .pi * (u * 3.1 - v * 2.3))
                let level = tone(min(max(0.5 + wave, 0.01), 0.99))
                let saturation = 0.25 + 0.35 * v
                let rgb = hsv(hue: u, saturation: saturation, value: level)
                let index = (y * width + x) * 4
                floats[index] = Float(AutoTone.linear(rgb.x))
                floats[index + 1] = Float(AutoTone.linear(rgb.y))
                floats[index + 2] = Float(AutoTone.linear(rgb.z))
            }
        }
        let image = TestImages.image(floats: floats, width: width, height: height)
        return Photo(url: URL(fileURLWithPath: "/tmp/scene.png"), source: .bitmap(image), fullSize: image.extent.size)
    }

    static func flat(level: Float) -> Photo {
        let image = TestImages.gray(level: level, size: 64)
        return Photo(url: URL(fileURLWithPath: "/tmp/flat.png"), source: .bitmap(image), fullSize: image.extent.size)
    }

    /// Two and a half stops under, in linear light.
    static let dark = scene { AutoTone.encoded(AutoTone.linear($0) * 0.18) }
    /// Washed out toward white, like an overexposed high-key shot.
    static let bright = scene { 1 - (1 - $0) * 0.3 }
    static let wellExposed = scene()

    static func number(in values: [String: [String: KnobValue]], plugin: String, param: String) -> Double {
        guard case .number(let value) = values[plugin]?[param] else { return .nan }
        return value
    }

    static func document(_ values: [String: [String: KnobValue]]) -> EditDocument {
        var document = EditDocument()
        for (pluginID, params) in values {
            guard let plugin = engine.plugin(id: pluginID) else { continue }
            for (paramID, value) in params {
                if let param = plugin.param(paramID) {
                    document.set(value: value, param: param, plugin: pluginID)
                }
            }
        }
        return document
    }

    @Suite("RenderEngine.autoTone")
    struct Solve {
        @Test("should keep every value finite and inside its param's range, even on a blank photo")
        func ranges() throws {
            let photos = [
                AutoToneTests.flat(level: 0),
                AutoToneTests.flat(level: 1),
                AutoToneTests.flat(level: 0.18),
                AutoToneTests.dark,
                AutoToneTests.bright,
                AutoToneTests.wellExposed,
            ]
            for photo in photos {
                let values = AutoToneTests.engine.autoTone(photo: photo, document: EditDocument())
                for (pluginID, params) in values {
                    let plugin = try #require(AutoToneTests.engine.plugin(id: pluginID))
                    for (paramID, value) in params {
                        let param = try #require(plugin.param(paramID))
                        guard case .slider(let slider) = param.kind, case .number(let number) = value else {
                            Issue.record("\(pluginID).\(paramID) is not a number")
                            continue
                        }
                        #expect(number.isFinite && slider.range.contains(number), "\(pluginID).\(paramID) = \(number)")
                    }
                }
            }
        }

        @Test("should set exactly Lightroom's Auto knobs and nothing else")
        func knobs() {
            let values = AutoToneTests.engine.autoTone(photo: AutoToneTests.wellExposed, document: EditDocument())
            #expect(values.mapValues { Set($0.keys) } == [
                "exposure": ["exposure"],
                "contrast": ["contrast"],
                "tone": ["highlights", "shadows", "whites", "blacks"],
                "vibrance": ["vibrance"],
                "saturation": ["saturation"],
            ])
        }

        @Test("should give a dark photo positive exposure")
        func dark() {
            let values = AutoToneTests.engine.autoTone(photo: AutoToneTests.dark, document: EditDocument())
            #expect(AutoToneTests.number(in: values, plugin: "exposure", param: "exposure") > 0.5, "\(values)")
        }

        @Test("should give a washed-out bright photo negative exposure")
        func bright() {
            let values = AutoToneTests.engine.autoTone(photo: AutoToneTests.bright, document: EditDocument())
            #expect(AutoToneTests.number(in: values, plugin: "exposure", param: "exposure") < -0.2)
        }

        @Test("should change a well-exposed photo only a little")
        func wellExposed() {
            let values = AutoToneTests.engine.autoTone(photo: AutoToneTests.wellExposed, document: EditDocument())
            #expect(abs(AutoToneTests.number(in: values, plugin: "exposure", param: "exposure")) <= 0.3, "\(values)")
            for (plugin, param) in [
                ("contrast", "contrast"), ("tone", "highlights"), ("tone", "shadows"), ("tone", "whites"), ("tone", "blacks"),
                ("vibrance", "vibrance"), ("saturation", "saturation"),
            ] {
                let value = AutoToneTests.number(in: values, plugin: plugin, param: param)
                #expect(abs(value) <= 20, "\(plugin).\(param) = \(value)")
            }
        }

        @Test("should return the same values every time")
        func deterministic() {
            let first = AutoToneTests.engine.autoTone(photo: AutoToneTests.bright, document: EditDocument())
            let second = AutoToneTests.engine.autoTone(photo: AutoToneTests.bright, document: EditDocument())
            #expect(first == second)
        }

        @Test("should ignore the values its own knobs already hold, so running it again changes nothing")
        func idempotent() {
            let photo = AutoToneTests.dark
            let first = AutoToneTests.engine.autoTone(photo: photo, document: EditDocument())
            let again = AutoToneTests.engine.autoTone(photo: photo, document: AutoToneTests.document(first))
            let pushed = AutoToneTests.document([
                "exposure": ["exposure": .number(3)],
                "contrast": ["contrast": .number(-80)],
                "tone": ["whites": .number(90), "shadows": .number(-60)],
                "vibrance": ["vibrance": .number(-100)],
            ])
            let overUserValues = AutoToneTests.engine.autoTone(photo: photo, document: pushed)
            #expect(again == first)
            #expect(overUserValues == first)
        }

        @Test("should measure the photo with the document's other edits in place")
        func keepsOtherEdits() throws {
            let curve = try #require(AutoToneTests.engine.plugin(id: "tone_curve")?.param("rgb"))
            var darkened = EditDocument()
            darkened.set(value: .curve([CurvePoint(x: 0, y: 0), CurvePoint(x: 0.5, y: 0.3), CurvePoint(x: 1, y: 1)]), param: curve, plugin: "tone_curve")
            let plain = AutoToneTests.engine.autoTone(photo: AutoToneTests.wellExposed, document: EditDocument())
            let underCurve = AutoToneTests.engine.autoTone(photo: AutoToneTests.wellExposed, document: darkened)
            let lifted = AutoToneTests.number(in: underCurve, plugin: "exposure", param: "exposure")
            #expect(lifted > AutoToneTests.number(in: plain, plugin: "exposure", param: "exposure") + 0.2)
        }
    }

    @Suite("clearing")
    struct Clearing {
        @Test("should drop only the knobs Auto sets")
        func clearsOwnKnobs() {
            var document = AutoToneTests.document([
                "exposure": ["exposure": .number(1)],
                "tone": ["highlights": .number(-40)],
                "white_balance": ["temp": .number(20)],
            ])
            let cleared = AutoTone.clearing(document)
            document.plugins["exposure"] = nil
            document.plugins["tone"] = nil
            #expect(cleared == document)
            #expect(cleared.values(for: "white_balance") == ["temp": .number(20)])
        }
    }

    private static func hsv(hue: Double, saturation: Double, value: Double) -> SIMD3<Double> {
        let sector = hue * 6
        let fraction = sector - floor(sector)
        let p = value * (1 - saturation)
        let q = value * (1 - saturation * fraction)
        let t = value * (1 - saturation * (1 - fraction))
        switch Int(sector) % 6 {
        case 0: return SIMD3(value, t, p)
        case 1: return SIMD3(q, value, p)
        case 2: return SIMD3(p, value, t)
        case 3: return SIMD3(p, q, value)
        case 4: return SIMD3(t, p, value)
        default: return SIMD3(value, p, q)
        }
    }
}
