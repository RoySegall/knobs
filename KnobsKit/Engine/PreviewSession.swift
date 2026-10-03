import CoreImage

/// Live-preview state for one photo at one size. Keeps the decoded, downscaled base between frames,
/// so moving a slider only re-runs the plugins. Built off the main thread, then used from one thread.
public final class PreviewSession: @unchecked Sendable {
    public let photo: Photo
    public let scale: Double
    private let engine: RenderEngine
    private let bitmapBase: CIImage?
    /// One decoder for the whole session: Core Image keeps its demosaic cached, so changing exposure
    /// or white balance costs ~2 ms instead of a ~200 ms re-decode.
    private let raw: (filter: CIRAWFilter, baseline: RAWBaseline)?

    init(engine: RenderEngine, photo: Photo, maxPixelSize: Int) {
        self.engine = engine
        self.photo = photo
        let scale = min(1, Double(maxPixelSize) / max(photo.fullSize.width, photo.fullSize.height))
        self.scale = scale
        switch photo.source {
        case .bitmap(let full):
            bitmapBase = engine.materialize(engine.downscale(full, scale: scale))
            raw = nil
        case .raw:
            bitmapBase = nil
            raw = photo.makeRAWFilter().map { filter in
                filter.scaleFactor = Float(scale)
                return (filter, RAWBaseline(filter: filter))
            }
        }
    }

    public var context: RenderContext {
        RenderContext(scale: scale, fullSize: photo.fullSize, source: photo.sourceKind, analysis: photo.analysis)
    }

    public func image(document: EditDocument, skipping: Set<String>, framing: Framing = .cropped) -> CIImage {
        let active = engine.active(document: document, skipping: skipping)
        let context = RenderContext(scale: scale, fullSize: photo.fullSize, source: photo.sourceKind, framing: framing, analysis: photo.analysis)
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

    private func rawBase(active: [ActivePlugin]) -> (image: CIImage, remaining: [ActivePlugin]) {
        guard let raw else { return (.empty(), active) }
        raw.baseline.restore(on: raw.filter)
        let remaining = active.filter { !$0.plugin.configure(raw: raw.filter, values: $0.values, context: context) }
        return (raw.filter.outputImage ?? .empty(), remaining)
    }
}
