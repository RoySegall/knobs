import CoreImage

/// Lightroom's Defringe: purple and green fringes on high-contrast edges lose their color to the
/// color beside them, at constant luminance. A colored object whose interior lies away from edges keeps its rim.
public struct LensCorrectionsPlugin: KnobPlugin {
    struct Band {
        let id: String
        let title: String
        /// OKLab hue at the left end of the hue sliders; each slider unit is `step` degrees.
        let startHue: Double
        let step: Double
        let defaultFrom: Double
        let defaultTo: Double

        func hue(position: Double) -> Double {
            startHue + step * position
        }
    }

    static let bands = [
        Band(id: "purple", title: "Purple", startHue: 270, step: 1.2, defaultFrom: 25, defaultTo: 75),
        Band(id: "green", title: "Green", startHue: 90, step: 1.2, defaultFrom: 35, defaultTo: 65),
    ]

    public let id = "lens_corrections"
    public let title = "Lens Corrections"
    public let panel = Panel(id: "lens_corrections", title: "Lens Corrections", order: 75)
    public let stage = Stage.scene
    /// Before dehaze: fringes are an optical artifact, removed before tone and color work amplify them.
    public let order = 10
    public let params: [KnobParam] = LensCorrectionsPlugin.bands.flatMap(LensCorrectionsPlugin.params)

    /// Full-resolution pixels per edge cell: a fringe reaches about one cell past its edge.
    static let edgeCell = 6.0
    /// Perceptual luma range within a cell's 3x3 neighbourhood that starts and completes an edge.
    static let edgeRamp = CIVector(x: 0.25, y: 0.5)
    /// Degrees over which a band fades out past its hue sliders.
    static let feather = 12.0
    /// Strength per unit of amount: from half the slider, a fringe fully inside the band is fully removed.
    static let gain = 2.0

    public init() {}

    public func apply(image: CIImage, values: KnobValues, context: RenderContext) -> CIImage {
        let extent = image.extent
        let amounts = Self.bands.map { values.number("\($0.id)_amount") / 100 }
        guard amounts.contains(where: { $0 > 0 }), !extent.isInfinite else { return image }
        let bands = zip(Self.bands, amounts).map { band, amount in
            Self.vector(band: band, amount: amount, values: values)
        }

        // Edges are measured on cells of about `edgeCell` full-resolution pixels, so the preview and the
        // export agree. Object context is read on blocks of two cells.
        let edgeFactor = max(1, 2 * (Self.edgeCell * context.scale / 2).rounded())
        let cells = Self.reduce(image, factor: edgeFactor)
        let range = KernelLibrary.general("lens_corrections_range").apply(
            extent: cells.extent,
            roiCallback: { _, rect in rect.insetBy(dx: -2, dy: -2) },
            arguments: [cells.clampedToExtent()]
        ) ?? .empty()
        let contextExtent = cells.extent.applying(CGAffineTransform(scaleX: 0.5, y: 0.5)).integral
        let contextArguments: [Any] = [cells.clampedToExtent(), range.clampedToExtent(), Self.edgeRamp] + bands
        let surroundings = KernelLibrary.general("lens_corrections_context").apply(
            extent: contextExtent,
            roiCallback: { _, rect in rect.applying(CGAffineTransform(scaleX: 2, y: 2)).insetBy(dx: -7, dy: -7) },
            arguments: contextArguments
        ) ?? .empty()

        let arguments: [Any] = [
            image,
            GuidedFilter.upsample(range, scale: 1 / edgeFactor, to: extent),
            GuidedFilter.upsample(surroundings, scale: 0.5 / edgeFactor, to: extent),
            Self.edgeRamp,
        ] + bands + [CIVector(x: amounts[0] * Self.gain, y: amounts[1] * Self.gain)]
        return KernelLibrary.color("lens_corrections_apply").apply(extent: extent, arguments: arguments) ?? image
    }

    /// (from, to, feather, active) in OKLab degrees, `from` inside 0..<360 and `to` after it.
    static func vector(band: Band, amount: Double, values: KnobValues) -> CIVector {
        let ends = [values.number("\(band.id)_hue_from"), values.number("\(band.id)_hue_to")].map(band.hue)
        let from = ends.min()!
        let to = ends.max()!
        let start = from.truncatingRemainder(dividingBy: 360)
        return CIVector(x: start, y: start + to - from, z: feather, w: amount > 0 ? 1 : 0)
    }

    /// Block mean, `factor` even or 1. The extent scales about the origin, like `GuidedFilter.downsample`.
    static func reduce(_ image: CIImage, factor: Double) -> CIImage {
        guard factor > 1 else { return image }
        let extent = image.extent.applying(CGAffineTransform(scaleX: 1 / factor, y: 1 / factor)).integral
        return KernelLibrary.general("lens_corrections_reduce").apply(
            extent: extent,
            roiCallback: { _, rect in rect.applying(CGAffineTransform(scaleX: factor, y: factor)).insetBy(dx: -1, dy: -1) },
            arguments: [image.clampedToExtent(), Float(factor)]
        ) ?? .empty()
    }

    private static func params(band: Band) -> [KnobParam] {
        let hues = Track.gradient((0...8).map { step in
            ColorOKLab.swatch(lightness: 0.62, chroma: 0.13, hue: band.hue(position: 100 * Double(step) / 8))
        })
        let center = band.hue(position: (band.defaultFrom + band.defaultTo) / 2)
        let amount = Track.gradient((0...4).map { step in
            ColorOKLab.swatch(lightness: 0.62, chroma: 0.13 * (1 - Double(step) / 4), hue: center)
        })
        return [
            .slider(id: "\(band.id)_amount", title: "\(band.title) Amount", range: 0...100, track: amount),
            .slider(id: "\(band.id)_hue_from", title: "\(band.title) Hue From", range: 0...100, default: band.defaultFrom, track: hues),
            .slider(id: "\(band.id)_hue_to", title: "\(band.title) Hue To", range: 0...100, default: band.defaultTo, track: hues),
        ]
    }
}
