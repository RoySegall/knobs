import CoreImage
import Foundation
import KnobsKit
import Metal

// Renders a photo through the plugin pipeline, for checking a knob's look without the app.
let usage = """
usage: knobs-render <input> <output.jpg|heic|tif|png> [--size N] [--side-by-side] [--sidecar file.knobs] [plugin.param=value ...]
       knobs-render --list
values: slider 0.5 · flag true · choice id · curve "0,0;0.5,0.6;1,1" · wheel "hue,amount"
"""

let engine = RenderEngine()
var arguments = Array(CommandLine.arguments.dropFirst())

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func describe(_ kind: KnobParam.Kind) -> String {
    switch kind {
    case .slider(let slider): "slider \(slider.range.lowerBound)...\(slider.range.upperBound) default \(slider.defaultValue)"
    case .flag(let value): "flag default \(value)"
    case .choice(let options, let value): "choice \(options.map(\.id).joined(separator: "|")) default \(value)"
    case .curve: "curve"
    case .wheel: "wheel"
    }
}

func parse(text: String, param: KnobParam) -> KnobValue? {
    switch param.kind {
    case .slider: return Double(text).map(KnobValue.number)
    case .flag: return Bool(text).map(KnobValue.flag)
    case .choice: return .choice(text)
    case .curve:
        let points = text.split(separator: ";").compactMap { pair -> CurvePoint? in
            let parts = pair.split(separator: ",").compactMap { Double($0) }
            return parts.count == 2 ? CurvePoint(x: parts[0], y: parts[1]) : nil
        }
        return points.count >= 2 ? .curve(points) : nil
    case .wheel:
        let parts = text.split(separator: ",").compactMap { Double($0) }
        return parts.count == 2 ? .wheel(Wheel(hue: parts[0], amount: parts[1])) : nil
    }
}

// knobs-render --bench <input> [plugin.param=value ...]: GPU time per preview frame at 4 MP while
// exposure moves underneath, so every downstream plugin re-runs each frame like during a drag.
if arguments.first == "--bench", arguments.count >= 2 {
    let photo = try Photo.load(url: URL(fileURLWithPath: arguments[1]))
    let session = engine.previewSession(photo: photo, maxPixelSize: 2048)
    let exposure = engine.plugin(id: "exposure")!.param("exposure")!
    var base = EditDocument()
    for argument in arguments.dropFirst(2) {
        let parts = argument.split(separator: "=", maxSplits: 1).map(String.init)
        let key = parts.first?.split(separator: ".").map(String.init) ?? []
        guard parts.count == 2, key.count == 2, let plugin = engine.plugin(id: key[0]), let param = plugin.param(key[1]),
              let value = parse(text: parts[1], param: param)
        else { fail("Bad value: \(argument)") }
        base.set(value: value, param: param, plugin: plugin.id)
    }
    let queue = engine.device.makeCommandQueue()!
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 2048, height: 2048, mipmapped: false)
    descriptor.usage = [.shaderWrite, .renderTarget]
    descriptor.storageMode = .private
    let texture = engine.device.makeTexture(descriptor: descriptor)!
    var times: [Double] = []
    for frame in 0..<40 {
        var document = base
        document.set(value: .number(Double(frame) / 400), param: exposure, plugin: "exposure")
        let start = Date()
        let buffer = queue.makeCommandBuffer()!
        let destination = CIRenderDestination(mtlTexture: texture, commandBuffer: buffer)
        _ = try? engine.context.startTask(toRender: session.image(document: document, skipping: []), to: destination)
        buffer.commit()
        buffer.waitUntilCompleted()
        times.append(Date().timeIntervalSince(start) * 1000)
    }
    let sorted = times.dropFirst(5).sorted()
    print(String(format: "first %.1f ms · median %.1f ms · p90 %.1f ms", times[0], sorted[sorted.count / 2], sorted[sorted.count * 9 / 10]))
    exit(0)
}

if arguments.first == "--list" {
    for plugin in engine.plugins {
        print("\(plugin.id)  [\(plugin.stage), \(plugin.panel.title)]")
        for param in plugin.params {
            print("  \(plugin.id).\(param.id)  \(describe(param.kind))")
        }
    }
    exit(0)
}

guard arguments.count >= 2 else { fail(usage) }
let input = URL(fileURLWithPath: arguments.removeFirst())
let output = URL(fileURLWithPath: arguments.removeFirst())
var size: Int?
var sideBySide = false
var document = EditDocument()

while !arguments.isEmpty {
    let argument = arguments.removeFirst()
    switch argument {
    case "--size":
        guard let value = arguments.first.flatMap({ Int($0) }) else { fail("--size needs a number") }
        size = value
        arguments.removeFirst()
    case "--side-by-side":
        sideBySide = true
    case "--sidecar":
        guard let path = arguments.first else { fail("--sidecar needs a path") }
        arguments.removeFirst()
        do {
            document = try JSONDecoder().decode(EditDocument.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        } catch {
            fail("Bad sidecar: \(error)")
        }
    default:
        let parts = argument.split(separator: "=", maxSplits: 1).map(String.init)
        let key = parts.first?.split(separator: ".").map(String.init) ?? []
        guard parts.count == 2, key.count == 2,
              let plugin = engine.plugin(id: key[0]),
              let param = plugin.param(key[1]),
              let value = parse(text: parts[1], param: param)
        else { fail("Bad value: \(argument)\n\(usage)") }
        document.set(value: value, param: param, plugin: plugin.id)
    }
}

let photo: Photo
do {
    photo = try Photo.load(url: input)
} catch {
    fail("Can't read \(input.path): \(error)")
}

let request = RenderRequest(maxPixelSize: size)
var image = engine.image(photo: photo, document: document, request: request)
if sideBySide {
    let original = engine.image(photo: photo, document: EditDocument(), request: request)
    let shifted = image.transformed(by: CGAffineTransform(translationX: original.extent.maxX + 16 - image.extent.minX, y: 0))
    let canvas = original.extent.union(shifted.extent)
    image = shifted.composited(over: original).composited(over: CIImage(color: .black).cropped(to: canvas))
}

let colorSpace = engine.displayColorSpace
do {
    switch output.pathExtension.lowercased() {
    case "jpg", "jpeg":
        try engine.context.writeJPEGRepresentation(of: image, to: output, colorSpace: colorSpace)
    case "heic":
        try engine.context.writeHEIFRepresentation(of: image, to: output, format: .RGBA8, colorSpace: colorSpace)
    case "tif", "tiff":
        try engine.context.writeTIFFRepresentation(of: image, to: output, format: .RGBA16, colorSpace: colorSpace)
    case "png":
        try engine.context.writePNGRepresentation(of: image, to: output, format: .RGBA8, colorSpace: colorSpace)
    default:
        fail("Unknown output type: \(output.pathExtension)")
    }
} catch {
    fail("Write failed: \(error)")
}
print(output.path)
