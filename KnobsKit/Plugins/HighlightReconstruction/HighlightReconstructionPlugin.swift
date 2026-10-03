import CoreImage

/// Rebuilds what the sensor clipped in a RAW, as Lightroom does, so pulling Highlights recovers a
/// soft bright area instead of a flat gray blob. The decoder writes clipped pixels as one exact value;
/// a work copy finds that plateau each frame, and push-pull fills it from the unclipped surroundings.
public struct HighlightReconstructionPlugin: KnobPlugin {
    public let id = "highlight_reconstruction"
    public let title = "Highlight Reconstruction"
    public let panel = Panel.light
    public let stage = Stage.raw
    /// After the plugins that configure the decoder, so it sees their exposure and white balance.
    public let order = 90
    /// Under Tone in the Light panel, beside the Highlights slider whose recovery it shapes.
    public let panelOrder = 35
    public let runsAtDefaults = true
    public let params: [KnobParam] = [
        .flag(id: "enabled", title: "Reconstruct Highlights", default: true),
    ]

    /// Long edge the work copy is reduced to: big enough for thin clipped rims, small enough to be cheap.
    static let workSize = 512.0
    /// The push-pull pyramid stops once a level's long edge is this short.
    static let coarsestSize = 8.0
    /// Depth each pyramid level adds where a pixel is inside a clipped area at that scale, finest first.
    /// The fine levels add little, so the climb starts gently at the edge; four levels is full depth.
    static let depthWeights: [Float] = [0.1, 0.2, 0.35, 0.35]
    /// Most a fully clipped area may climb above its clip level, in stops.
    static let maxRise: Float = 2

    public init() {}

    public func apply(image: CIImage, values: KnobValues, context: RenderContext) -> CIImage {
        guard context.source == .raw, values.flag("enabled") else { return image }
        let extent = image.extent
        guard extent.width >= 2, extent.height >= 2, !extent.isInfinite else { return image }
        // The work copy and its pyramid live at the origin, so a block maps to whole pixels.
        let origin = CGAffineTransform(translationX: -extent.minX, y: -extent.minY)
        let source = image.transformed(by: origin)
        let bounds = CGRect(origin: .zero, size: extent.size)

        let factor = max(2, (max(bounds.width, bounds.height) / Self.workSize).rounded(.up))
        let work = Self.reduce(image: source, factor: factor, bounds: bounds)
        let levels = Self.levels(work: work)
        let fields = Self.fields(work: work, levels: levels)
            .clampedToExtent()
            .samplingLinear()
            .transformed(by: CGAffineTransform(scaleX: factor, y: factor))
            .cropped(to: bounds)
        let output = KernelLibrary.general("highlight_reconstruction_apply").apply(
            extent: bounds,
            roiCallback: { index, rect in index == 0 ? rect.insetBy(dx: -2, dy: -2).intersection(bounds) : rect },
            arguments: [source, fields, levels, Self.maxRise, CIVector(cgRect: bounds)]
        ) ?? source
        return output.transformed(by: origin.inverted())
    }

    /// Block means of the full-size image, with flags for blocks that are a single value.
    static func reduce(image: CIImage, factor: Double, bounds: CGRect) -> CIImage {
        let extent = CGRect(x: 0, y: 0, width: (bounds.width / factor).rounded(.up), height: (bounds.height / factor).rounded(.up))
        return KernelLibrary.general("highlight_reconstruction_reduce").apply(
            extent: extent,
            roiCallback: { _, rect in
                CGRect(x: rect.minX * factor, y: rect.minY * factor, width: rect.width * factor, height: rect.height * factor)
                    .intersection(bounds)
            },
            arguments: [image, Float(factor), CIVector(cgRect: bounds)]
        ) ?? .empty()
    }

    /// Clip level per channel (rgb), and 1 in alpha if there is a plateau, as a constant image measured on
    /// the GPU every frame: exposure and white balance move the plateau, so a level read at load goes stale.
    static func levels(work: CIImage) -> CIImage {
        var top = KernelLibrary.general("highlight_reconstruction_top_values").apply(
            extent: work.extent,
            roiCallback: { _, rect in rect.insetBy(dx: -1, dy: -1) },
            arguments: [work, CIVector(cgRect: work.extent)]
        ) ?? .empty()
        while max(top.extent.width, top.extent.height) > 1 {
            top = shrink(image: top, by: 8, kernel: "highlight_reconstruction_max8")
        }
        return color(name: "highlight_reconstruction_levels", extent: top.extent, arguments: [top]).clampedToExtent()
    }

    /// Push-pull over a 4× pyramid of the work copy: surrounding chroma (rg), surrounding log2
    /// luminance (b) and clip depth (a), defined everywhere and smooth.
    static func fields(work: CIImage, levels: CIImage) -> CIImage {
        var colors = [color(name: "highlight_reconstruction_seed_color", extent: work.extent, arguments: [work, levels])]
        var clips = [color(name: "highlight_reconstruction_seed_clip", extent: work.extent, arguments: [work, levels])]
        while let last = colors.last, max(last.extent.width, last.extent.height) > coarsestSize {
            colors.append(shrink(image: last, by: 4, kernel: "highlight_reconstruction_down4"))
            clips.append(shrink(image: clips[clips.count - 1], by: 4, kernel: "highlight_reconstruction_down4"))
        }
        var pulled = color(name: "highlight_reconstruction_fallback", extent: CGRect(x: 0, y: 0, width: 1, height: 1), arguments: [levels])
            .clampedToExtent()
        for (level, (seed, clip)) in zip(colors, clips).enumerated().reversed() {
            let coarse = pulled.extent.isInfinite
                ? pulled
                : pulled.clampedToExtent().samplingLinear().transformed(by: CGAffineTransform(scaleX: 4, y: 4))
            // The finest level's colors are single textured blocks; the next one up averages them out.
            let trust: Float = level == 0 ? 0 : 1
            let depth = Self.depthWeights[min(level, Self.depthWeights.count - 1)]
            pulled = color(name: "highlight_reconstruction_pull", extent: seed.extent, arguments: [seed, clip, coarse, depth, trust])
        }
        return pulled
    }

    /// 1/n size, `kernel` combining each n×n block. Kernels clamp to the source, so no clamped copy is made.
    private static func shrink(image: CIImage, by n: Double, kernel: String) -> CIImage {
        let source = image.extent
        let extent = CGRect(x: 0, y: 0, width: (source.width / n).rounded(.up), height: (source.height / n).rounded(.up))
        return KernelLibrary.general(kernel).apply(
            extent: extent,
            roiCallback: { _, rect in rect.applying(CGAffineTransform(scaleX: n, y: n)).insetBy(dx: -1, dy: -1).intersection(source) },
            arguments: [image, CIVector(cgRect: source)]
        ) ?? .empty()
    }

    private static func color(name: String, extent: CGRect, arguments: [Any]) -> CIImage {
        KernelLibrary.color(name).apply(extent: extent, arguments: arguments) ?? .empty()
    }
}
