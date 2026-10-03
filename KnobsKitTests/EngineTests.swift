import CoreImage
import Foundation
import Testing
@testable import KnobsKit

/// Doubles every pixel, so tests can tell whether and in which order it ran.
private struct DoublerPlugin: KnobPlugin {
    var id = "doubler"
    var title = "Doubler"
    var panel = Panel.light
    var stage = Stage.tone
    var order = 10
    let params: [KnobParam] = [.slider(id: "amount", title: "Amount", range: 0...1)]

    init() {}

    init(id: String, stage: Stage, order: Int) {
        self.id = id
        self.stage = stage
        self.order = order
    }

    func apply(image: CIImage, values: KnobValues, context: RenderContext) -> CIImage {
        image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 2, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 2, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 2, w: 0),
        ])
    }
}

@Suite("Engine")
struct EngineTests {
    @Suite("RenderEngine.image")
    struct Image {
        let photo: Photo = {
            let image = TestImages.gray(level: 0.25, size: 64)
            return Photo(url: URL(fileURLWithPath: "/tmp/gray.png"), source: .bitmap(image), fullSize: image.extent.size)
        }()

        func document(_ pluginIDs: [String]) -> EditDocument {
            var document = EditDocument()
            let param = DoublerPlugin().params[0]
            for id in pluginIDs {
                document.set(value: .number(1), param: param, plugin: id)
            }
            return document
        }

        @Test("should skip a plugin whose values are all defaults")
        func skipsNeutral() {
            let engine = RenderEngine(plugins: [DoublerPlugin()])
            let output = engine.image(photo: photo, document: EditDocument(), request: RenderRequest())
            #expect(abs(Pixels.mean(output).x - 0.25) < 1e-3)
        }

        @Test("should leave out plugins named in the request")
        func skipsRequested() {
            let engine = RenderEngine(plugins: [DoublerPlugin()])
            let request = RenderRequest(skipping: ["doubler"])
            let output = engine.image(photo: photo, document: document(["doubler"]), request: request)
            #expect(abs(Pixels.mean(output).x - 0.25) < 1e-3)
        }

        @Test("should downscale to the requested longest edge")
        func downscales() {
            let engine = RenderEngine(plugins: [])
            let output = engine.image(photo: photo, document: EditDocument(), request: RenderRequest(maxPixelSize: 32))
            #expect(output.extent.size == CGSize(width: 32, height: 32))
        }

        @Test("should run an edited plugin")
        func runsEdited() {
            let engine = RenderEngine(plugins: [DoublerPlugin()])
            let output = engine.image(photo: photo, document: document(["doubler"]), request: RenderRequest())
            #expect(abs(Pixels.mean(output).x - 0.5) < 1e-3)
        }

        @Test("should order plugins by stage, then by order")
        func orders() {
            let engine = RenderEngine(plugins: [
                DoublerPlugin(id: "c", stage: .effects, order: 1),
                DoublerPlugin(id: "b", stage: .tone, order: 20),
                DoublerPlugin(id: "a", stage: .tone, order: 10),
                DoublerPlugin(id: "r", stage: .raw, order: 99),
            ])
            #expect(engine.plugins.map(\.id) == ["r", "a", "b", "c"])
        }
    }

    @Suite("EditDocument")
    struct Document {
        let param = KnobParam.slider(id: "amount", title: "Amount", range: -100...100)

        @Test("should throw on a corrupt sidecar instead of returning an empty document")
        func corrupt() throws {
            let photo = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).jpg")
            try Data("not json".utf8).write(to: EditDocument.sidecarURL(for: photo))
            #expect(throws: (any Error).self) { try EditDocument.load(for: photo) }
        }

        @Test("should drop a value set back to its default")
        func dropsDefault() {
            var document = EditDocument()
            document.set(value: .number(40), param: param, plugin: "contrast")
            document.set(value: .number(0), param: param, plugin: "contrast")
            #expect(document.isEmpty)
        }

        @Test("should round-trip through the sidecar and delete it once empty")
        func roundTrip() throws {
            let photo = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).cr3")
            var document = EditDocument()
            document.set(value: .number(40), param: param, plugin: "contrast")
            document.set(value: .curve([CurvePoint(x: 0, y: 0.1), CurvePoint(x: 1, y: 0.9)]), param: .curve(id: "rgb", title: "RGB"), plugin: "curve")
            document.set(value: .wheel(Wheel(hue: 200, amount: 0.3)), param: .wheel(id: "shadows", title: "Shadows"), plugin: "grading")
            try document.save(for: photo)
            let loaded = try EditDocument.load(for: photo)
            #expect(loaded == document)

            document.resetAll()
            try document.save(for: photo)
            #expect(!FileManager.default.fileExists(atPath: EditDocument.sidecarURL(for: photo).path))
        }
    }

    @Suite("KnobValues")
    struct Values {
        let params: [KnobParam] = [
            .slider(id: "amount", title: "Amount", range: -100...100, default: 10),
            .flag(id: "on", title: "On"),
        ]

        @Test("should fall back to the default when a stored value has the wrong type")
        func wrongType() {
            let values = KnobValues(params: params, stored: ["amount": .flag(true)])
            #expect(values.number("amount") == 10)
        }

        @Test("should clamp a slider value to its range")
        func clamps() {
            let values = KnobValues(params: params, stored: ["amount": .number(500)])
            #expect(values.number("amount") == 100)
        }

        @Test("should report neutral only when every value is the default")
        func neutral() {
            #expect(KnobValues(params: params, stored: [:]).isNeutral(params: params))
            #expect(!KnobValues(params: params, stored: ["on": .flag(true)]).isNeutral(params: params))
        }
    }
}
