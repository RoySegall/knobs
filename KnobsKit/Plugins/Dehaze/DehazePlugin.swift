import CoreImage

/// Dark channel prior dehaze (He et al. 2009) in the linear working space, where the haze model
/// I = J·t + A·(1 − t) is physically true. Transmission is solved at a fixed small size and brought
/// back to full resolution by a color guided filter, so the preview and the export agree.
public struct DehazePlugin: KnobPlugin {
    public let id = "dehaze"
    public let title = "Dehaze"
    public let panel = Panel.presence
    public let stage = Stage.scene
    /// After texture (10) and clarity (20) in the Presence panel, like Lightroom.
    public let order = 30
    public let params: [KnobParam] = [
        .slider(id: "amount", title: "Dehaze", range: -100...100),
    ]

    /// Long edge of the copy the transmission is solved on, and of the one the airlight is read from.
    static let workSize = 480.0
    static let airlightSize = 64.0
    /// Dark-channel patch and guided-filter window radii as fractions of the work copy's long edge.
    static let patchRadius = 0.005
    static let refineRadius = 0.0125
    static let epsilon = 2e-4
    /// Lowest transmission, and how close to the airlight (in the encoded guide) a pixel counts as sky.
    static let floor: Float = 0.15
    static let skyTolerance: Float = 0.03

    public init() {}

    public func apply(image: CIImage, values: KnobValues, context: RenderContext) -> CIImage {
        let amount = values.number("amount") / 100
        guard amount != 0 else { return image }
        let extent = image.extent
        let scale = min(1, Self.workSize / max(extent.width, extent.height))
        let work = GuidedFilter.downsample(image, scale: scale)
        let workExtent = work.extent
        let workLong = max(workExtent.width, workExtent.height)
        let airlight = Self.airlight(work: work)

        let guide = Self.color("dehaze_guide", extent: workExtent, arguments: [work, airlight])
        let darkPixel = Self.color("dehaze_dark_pixel", extent: workExtent, arguments: [work, airlight])
        // Opening (min then max) keeps the dark channel's edges where the objects' edges are.
        let patch = max(1, (Self.patchRadius * workLong).rounded())
        let dark = Self.maximum(Self.minimum(darkPixel, radius: patch), radius: patch)
        let smoothGuide = GuidedFilter.boxMean(guide, radius: patch)
        let haze = Self.color("dehaze_haze", extent: workExtent, arguments: [dark, smoothGuide, airlight, Self.floor, Self.skyTolerance])
        let coefficients = GuidedFilter.colorCoefficients(
            guide: guide,
            input: haze,
            radius: max(1, Self.refineRadius * workLong),
            epsilon: Self.epsilon,
            guideCenter: CIVector(x: 0.95, y: 0.95, z: 0.95)
        )
        let refine = GuidedFilter.upsample(coefficients, scale: scale, to: extent)
        return KernelLibrary.general("dehaze_apply").apply(
            extent: extent,
            roiCallback: { index, rect in index == 1 ? rect.insetBy(dx: -1, dy: -1) : rect },
            arguments: [image, image.clampedToExtent(), refine, airlight, Float(amount), Self.floor]
        ) ?? image
    }

    /// The airlight as a constant image, estimated on the GPU every frame with no readback: the
    /// weighted mean color of the region whose dark channel is within 10% of the brightest.
    static func airlight(work: CIImage) -> CIImage {
        let tiny = GuidedFilter.downsample(work, scale: min(1, airlightSize / max(work.extent.width, work.extent.height)))
        let extent = tiny.extent
        let region = CIVector(cgRect: extent)
        let dark = minimum(color("dehaze_min_channel", extent: extent, arguments: [tiny]), radius: 2)
        let peak = dark.applyingFilter("CIAreaMaximum", parameters: [kCIInputExtentKey: region]).clampedToExtent()
        let weighted = color("dehaze_airlight_weighted", extent: extent, arguments: [tiny, dark, peak])
        let average = weighted.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: region])
        return color("dehaze_airlight", extent: average.extent, arguments: [average]).clampedToExtent()
    }

    /// Square min filter: the dark channel's patch.
    static func minimum(_ image: CIImage, radius: Double) -> CIImage {
        morphology("CIMorphologyRectangleMinimum", image: image, radius: radius)
    }

    static func maximum(_ image: CIImage, radius: Double) -> CIImage {
        morphology("CIMorphologyRectangleMaximum", image: image, radius: radius)
    }

    private static func morphology(_ name: String, image: CIImage, radius: Double) -> CIImage {
        let size = 2 * radius.rounded() + 1
        return image.clampedToExtent()
            .applyingFilter(name, parameters: ["inputWidth": size, "inputHeight": size])
            .cropped(to: image.extent)
    }

    private static func color(_ name: String, extent: CGRect, arguments: [Any]) -> CIImage {
        KernelLibrary.color(name).apply(extent: extent, arguments: arguments) ?? .empty()
    }
}
