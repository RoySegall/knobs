import CoreImage
import Metal
import UniformTypeIdentifiers

struct ActivePlugin {
    let plugin: any KnobPlugin
    let values: KnobValues
}

public struct RenderRequest: Sendable {
    /// Longest edge in pixels; nil renders full resolution.
    public var maxPixelSize: Int?
    /// Plugin ids to leave out, e.g. geometry while the crop tool is open.
    public var skipping: Set<String>

    public init(maxPixelSize: Int? = nil, skipping: Set<String> = []) {
        self.maxPixelSize = maxPixelSize
        self.skipping = skipping
    }
}

public enum ExportFormat: String, Sendable, CaseIterable {
    case jpeg
    case heic
    case tiff

    public var fileExtension: String {
        switch self {
        case .jpeg: "jpg"
        case .heic: "heic"
        case .tiff: "tif"
        }
    }
}

public final class RenderEngine: Sendable {
    public let plugins: [any KnobPlugin]
    public let device: any MTLDevice
    public let context: CIContext
    public let displayColorSpace = CGColorSpace(name: CGColorSpace.displayP3)!

    public init(plugins: [any KnobPlugin] = PluginRegistry.all) {
        self.plugins = plugins.sorted { ($0.stage, $0.order) < ($1.stage, $1.order) }
        device = MTLCreateSystemDefaultDevice()!
        context = CIContext(mtlDevice: device, options: [
            .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
            .workingFormat: CIFormat.RGBAh,
        ])
    }

    public func plugin(id: String) -> (any KnobPlugin)? {
        plugins.first { $0.id == id }
    }

    public func image(photo: Photo, document: EditDocument, request: RenderRequest) -> CIImage {
        let longest = max(photo.fullSize.width, photo.fullSize.height)
        let scale = request.maxPixelSize.map { min(1, Double($0) / longest) } ?? 1
        let context = RenderContext(scale: scale, fullSize: photo.fullSize, source: photo.sourceKind)
        var active = active(document: document, skipping: request.skipping)

        let base: CIImage
        switch photo.source {
        case .raw:
            guard let filter = photo.makeRAWFilter() else { return .empty() }
            filter.scaleFactor = Float(scale)
            active.removeAll { $0.plugin.configure(raw: filter, values: $0.values, context: context) }
            base = filter.outputImage ?? .empty()
        case .bitmap(let full):
            base = downscale(full, scale: scale)
        }
        return process(image: base, plugins: active, context: context)
    }

    /// A live-preview session that caches the decoded base between frames.
    public func previewSession(photo: Photo, maxPixelSize: Int) -> PreviewSession {
        PreviewSession(engine: self, photo: photo, maxPixelSize: maxPixelSize)
    }

    func active(document: EditDocument, skipping: Set<String>) -> [ActivePlugin] {
        plugins.compactMap { plugin in
            guard !skipping.contains(plugin.id) else { return nil }
            let values = KnobValues(params: plugin.params, stored: document.values(for: plugin.id))
            return values.isNeutral(params: plugin.params) ? nil : ActivePlugin(plugin: plugin, values: values)
        }
    }

    func process(image: CIImage, plugins active: [ActivePlugin], context: RenderContext) -> CIImage {
        active.reduce(image) { image, entry in
            entry.plugin.apply(image: image, values: entry.values, context: context)
        }
    }

    func downscale(_ image: CIImage, scale: Double) -> CIImage {
        guard scale < 1 else { return image }
        return image.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1])
    }

    public func cgImage(photo: Photo, document: EditDocument, request: RenderRequest) -> CGImage? {
        let image = image(photo: photo, document: document, request: request)
        return context.createCGImage(image, from: image.extent.integral, format: .RGBA8, colorSpace: displayColorSpace)
    }

    public func export(photo: Photo, document: EditDocument, format: ExportFormat, to url: URL) throws {
        let image = image(photo: photo, document: document, request: RenderRequest())
        let quality = [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.92]
        switch format {
        case .jpeg:
            try context.writeJPEGRepresentation(of: image, to: url, colorSpace: displayColorSpace, options: quality)
        case .heic:
            try context.writeHEIFRepresentation(of: image, to: url, format: .RGBA8, colorSpace: displayColorSpace, options: quality)
        case .tiff:
            try context.writeTIFFRepresentation(of: image, to: url, format: .RGBA16, colorSpace: displayColorSpace)
        }
    }
}
