import CoreImage

/// Lightroom's Highlights, Shadows, Whites and Blacks. Highlights and shadows change exposure by
/// region, read off an edge-aware smoothed luminance, so local contrast survives and edges don't halo.
/// Whites and blacks bend the ends of the tone scale and clip at the extremes.
public struct TonePlugin: KnobPlugin {
    public let id = "tone"
    public let title = "Tone"
    public let panel = Panel.light
    public let stage = Stage.tone
    public let order = 30
    public let params: [KnobParam] = [
        .slider(id: "highlights", title: "Highlights", range: -100...100),
        .slider(id: "shadows", title: "Shadows", range: -100...100),
        .slider(id: "whites", title: "Whites", range: -100...100),
        .slider(id: "blacks", title: "Blacks", range: -100...100),
    ]

    /// Smoothing radius as a fraction of the photo's long side, so it covers the same area at any size.
    static let radiusFraction = 0.02
    /// The base is solved at a size where the radius is this many pixels; the full-size guide restores edges.
    static let reducedRadius = 6.0
    /// Guided-filter epsilon in squared stops: luminance steps well above √ε are treated as edges.
    static let epsilon: Float = 0.15

    public init() {}

    public func apply(image: CIImage, values: KnobValues, context: RenderContext) -> CIImage {
        let strengths = Strengths(values: values)
        guard strengths != Strengths.neutral else { return image }
        guard strengths.highlights != 0 || strengths.shadows != 0 else {
            return KernelLibrary.color("tone_ends").apply(
                extent: image.extent,
                arguments: [image, strengths.whites, strengths.blacks]
            ) ?? image
        }
        guard let coefficients = Self.baseCoefficients(image: image, context: context) else { return image }
        return KernelLibrary.color("tone_apply").apply(
            extent: image.extent,
            arguments: [image, coefficients, strengths.highlights, strengths.shadows, strengths.whites, strengths.blacks]
        ) ?? image
    }

    /// Kernel arguments for the slider values. Each direction is scaled on its own so both ends of
    /// every slider are as strong as they can be without folding the curve back.
    struct Strengths: Equatable {
        static let neutral = Strengths(highlights: 0, shadows: 0, whites: 0, blacks: 0)

        /// Fraction of the distance above mid-gray removed (minus) or added (plus).
        let highlights: Float
        /// Stops added at the darkest regions.
        let shadows: Float
        /// Plus is the stretch past the white knee, minus the compression.
        let whites: Float
        /// Minus is the stretch past the black knee, plus the lift.
        let blacks: Float

        init(highlights: Float, shadows: Float, whites: Float, blacks: Float) {
            self.highlights = highlights
            self.shadows = shadows
            self.whites = whites
            self.blacks = blacks
        }

        init(values: KnobValues) {
            func scaled(id: String, minus: Double, plus: Double) -> Float {
                let value = values.number(id) / 100
                return Float(value * (value < 0 ? minus : plus))
            }
            highlights = scaled(id: "highlights", minus: 0.5, plus: 0.3)
            shadows = scaled(id: "shadows", minus: 1.5, plus: 2.0)
            whites = scaled(id: "whites", minus: 0.67, plus: 1.1)
            blacks = scaled(id: "blacks", minus: 0.6, plus: 0.7)
        }
    }

    /// Fast guided filter on log luminance: statistics at reduced size, then `a·L + b` per full-size pixel.
    /// Luminance goes to log before the reduction so the means are means of stops, as the filter needs.
    static func baseCoefficients(image: CIImage, context: RenderContext) -> CIImage? {
        let extent = image.extent
        let radius = radiusFraction * max(context.fullSize.width, context.fullSize.height) * context.scale
        let reduction = min(1, reducedRadius / max(radius, 1))
        let reducedExtent = extent.applying(CGAffineTransform(scaleX: reduction, y: reduction))
        let blurRadius = max(radius * reduction, 1)

        guard let fullLuminance = KernelLibrary.color("tone_log_luminance").apply(extent: extent, arguments: [image])
        else { return nil }
        let luminance = reduction < 1
            ? fullLuminance.clampedToExtent()
                .transformed(by: CGAffineTransform(scaleX: reduction, y: reduction), highQualityDownsample: true)
                .cropped(to: reducedExtent)
            : fullLuminance
        let mean = boxBlur(image: luminance, radius: blurRadius)
        guard let deviation = KernelLibrary.color("tone_deviation").apply(extent: reducedExtent, arguments: [luminance, mean])
        else { return nil }
        let variance = boxBlur(image: deviation, radius: blurRadius)
        guard let coefficients = KernelLibrary.color("tone_coefficients")
            .apply(extent: reducedExtent, arguments: [mean, variance, epsilon])
        else { return nil }

        return boxBlur(image: coefficients, radius: blurRadius)
            .clampedToExtent()
            .samplingLinear()
            .transformed(by: CGAffineTransform(scaleX: 1 / reduction, y: 1 / reduction))
            .cropped(to: extent)
    }

    private static func boxBlur(image: CIImage, radius: Double) -> CIImage {
        image.clampedToExtent()
            .applyingFilter("CIBoxBlur", parameters: [kCIInputRadiusKey: radius])
            .cropped(to: image.extent)
    }
}
