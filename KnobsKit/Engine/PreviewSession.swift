import CoreImage

/// Live-preview state for one photo at one size. Keeps the decoded, downscaled base between frames,
/// so moving a slider only re-runs the plugins. Not thread-safe: use it from one thread.
public final class PreviewSession {
    public let photo: Photo
    public let scale: Double
    private let engine: RenderEngine
    private let bitmapBase: CIImage?
    private var rawCache: (key: [String: KnobValues], image: CIImage)?

    init(engine: RenderEngine, photo: Photo, maxPixelSize: Int) {
        self.engine = engine
        self.photo = photo
        scale = min(1, Double(maxPixelSize) / max(photo.fullSize.width, photo.fullSize.height))
        if case .bitmap(let full) = photo.source {
            bitmapBase = engine.downscale(full, scale: scale).insertingIntermediate(cache: true)
        } else {
            bitmapBase = nil
        }
    }

    public var context: RenderContext {
        RenderContext(scale: scale, fullSize: photo.fullSize, source: photo.sourceKind)
    }

    public func image(document: EditDocument, skipping: Set<String>) -> CIImage {
        let active = engine.active(document: document, skipping: skipping)
        if let bitmapBase {
            return engine.process(image: bitmapBase, plugins: active, context: context)
        }
        let raw = rawBase(active: active)
        return engine.process(image: raw.image, plugins: raw.remaining, context: context)
    }

    public func cgImage(document: EditDocument, skipping: Set<String>) -> CGImage? {
        let image = image(document: document, skipping: skipping)
        return engine.context.createCGImage(image, from: image.extent.integral, format: .RGBA8, colorSpace: engine.displayColorSpace)
    }

    /// Decodes again only when a value the decoder consumed has changed.
    private func rawBase(active: [ActivePlugin]) -> (image: CIImage, remaining: [ActivePlugin]) {
        guard let filter = photo.makeRAWFilter() else { return (.empty(), active) }
        filter.scaleFactor = Float(scale)
        var handled: [String: KnobValues] = [:]
        let remaining = active.filter { entry in
            guard entry.plugin.configure(raw: filter, values: entry.values, context: context) else { return true }
            handled[entry.plugin.id] = entry.values
            return false
        }
        if let rawCache, rawCache.key == handled {
            return (rawCache.image, remaining)
        }
        let image = (filter.outputImage ?? .empty()).insertingIntermediate(cache: true)
        rawCache = (handled, image)
        return (image, remaining)
    }
}
