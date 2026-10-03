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
    /// Plugin ids to leave out of the render.
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

    var typeIdentifier: String {
        switch self {
        case .jpeg: UTType.jpeg.identifier
        case .heic: UTType.heic.identifier
        case .tiff: UTType.tiff.identifier
        }
    }

    public var fileExtension: String {
        switch self {
        case .jpeg: "jpg"
        case .heic: "heic"
        case .tiff: "tif"
        }
    }
}

public struct ExportOptions: Sendable, Equatable {
    public var format: ExportFormat
    /// 0...1, for JPEG and HEIC.
    public var quality: Double
    /// Longest edge in pixels; nil exports full resolution.
    public var maxPixelSize: Int?

    public init(format: ExportFormat, quality: Double = 0.92, maxPixelSize: Int? = nil) {
        self.format = format
        self.quality = quality
        self.maxPixelSize = maxPixelSize
    }
}

public final class RenderEngine: Sendable {
    public let plugins: [any KnobPlugin]
    public let device: any MTLDevice
    public let context: CIContext
    let queue: any MTLCommandQueue
    let workingColorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    public let displayColorSpace = CGColorSpace(name: CGColorSpace.displayP3)!

    public init(plugins: [any KnobPlugin] = PluginRegistry.all) {
        self.plugins = plugins.sorted { ($0.stage, $0.order) < ($1.stage, $1.order) }
        device = MTLCreateSystemDefaultDevice()!
        queue = device.makeCommandQueue()!
        context = CIContext(mtlDevice: device, options: [
            .workingColorSpace: workingColorSpace,
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
        let edited = active.reduce(image) { image, entry in
            entry.plugin.apply(image: image, values: entry.values, context: context)
        }
        return display(edited, source: context.source)
    }

    /// Where a RAW's decoded highlights end, in linear units, with `Photo.rawHeadroom` applied.
    static let rawWhite: Float = 4

    /// Rolls highlights into display range. RAW keeps ~2 stops above white, so its shoulder starts
    /// below 1; a bitmap ends at 1 and passes through untouched unless an edit pushed it past white.
    func display(_ image: CIImage, source: RenderContext.Source) -> CIImage {
        let (knee, white): (Float, Float) = switch source {
        case .raw: (0.9, Self.rawWhite)
        case .bitmap: (0.9, 1)
        }
        let bounds = CIVector(cgRect: image.extent)
        return KernelLibrary.color("display_rolloff").apply(extent: image.extent, arguments: [image, knee, white, bounds]) ?? image
    }

    /// Renders an image into a GPU texture once, so later frames sample pixels instead of
    /// re-running its graph (file decode, resampling) whenever Core Image's cache lets go.
    func materialize(_ image: CIImage) -> CIImage {
        let extent = image.extent.integral
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: Int(extent.width),
            height: Int(extent.height),
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        descriptor.storageMode = .private
        guard let texture = device.makeTexture(descriptor: descriptor), let buffer = queue.makeCommandBuffer() else { return image }
        let destination = CIRenderDestination(mtlTexture: texture, commandBuffer: buffer)
        destination.colorSpace = workingColorSpace
        let origin = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
        guard (try? context.startTask(toRender: origin, to: destination)) != nil else { return image }
        buffer.commit()
        buffer.waitUntilCompleted()
        return CIImage(mtlTexture: texture, options: [.colorSpace: workingColorSpace]) ?? image
    }

    func downscale(_ image: CIImage, scale: Double) -> CIImage {
        guard scale < 1 else { return image }
        return image.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1])
    }

    public func cgImage(photo: Photo, document: EditDocument, request: RenderRequest) -> CGImage? {
        let image = image(photo: photo, document: document, request: request)
        return context.createCGImage(image, from: image.extent.integral, format: .RGBA8, colorSpace: displayColorSpace)
    }

    public enum ExportError: Error {
        case render
        case write(URL)
    }

    /// Writes through ImageIO rather than Core Image's writers so the original's metadata can come along.
    public func export(photo: Photo, document: EditDocument, options: ExportOptions, to url: URL) throws {
        let image = image(photo: photo, document: document, request: RenderRequest(maxPixelSize: options.maxPixelSize))
        let extent = image.extent.integral
        let depth: CIFormat = options.format == .tiff ? .RGBA16 : .RGBA8
        guard let rendered = context.createCGImage(image, from: extent, format: depth, colorSpace: displayColorSpace) else {
            throw ExportError.render
        }
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, options.format.typeIdentifier as CFString, 1, nil) else {
            throw ExportError.write(url)
        }
        var properties = ExportMetadata.properties(from: photo.url, size: extent.size)
        switch options.format {
        case .jpeg, .heic:
            properties[kCGImageDestinationLossyCompressionQuality] = options.quality
        case .tiff:
            var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
            tiff[kCGImagePropertyTIFFCompression] = 5
            properties[kCGImagePropertyTIFFDictionary] = tiff
        }
        CGImageDestinationAddImage(destination, rendered, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ExportError.write(url) }
    }
}
