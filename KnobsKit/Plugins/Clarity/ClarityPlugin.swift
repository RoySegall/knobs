import CoreImage

/// Midtone local contrast at a large radius. The base it contrasts against comes from a guided filter
/// on luminance, which follows strong edges, so there are no halos around them.
public struct ClarityPlugin: KnobPlugin {
    public let id = "clarity"
    public let title = "Clarity"
    public let panel = Panel.presence
    public let stage = Stage.presence
    public let order = 20
    public let params: [KnobParam] = [
        .slider(id: "amount", title: "Clarity", range: -100...100),
    ]

    /// Window radius as a fraction of the photo's long edge, so every camera gets the same look.
    static let radius = 0.012
    /// Guided-filter epsilon on sRGB-encoded luminance: local deviations above about 0.07 count as edges.
    static let epsilon = 0.005
    /// Window radius in pixels on the small copy the coefficients are solved on.
    static let solveRadius = 8.0

    public init() {}

    public func apply(image: CIImage, values: KnobValues, context: RenderContext) -> CIImage {
        let amount = values.number("amount") / 100
        guard amount != 0 else { return image }
        let extent = image.extent
        guard let luminance = KernelLibrary.color("presence_luminance").apply(extent: extent, arguments: [image]) else { return image }
        let radius = Self.radius * max(context.fullSize.width, context.fullSize.height) * context.scale
        let scale = min(1, Self.solveRadius / radius)
        let small = GuidedFilter.downsample(luminance, scale: scale)
        let coefficients = GuidedFilter.grayCoefficients(guide: small, radius: radius * scale, epsilon: Self.epsilon)
        let upsampled = GuidedFilter.upsample(coefficients, scale: scale, to: extent)
        let structure = GuidedFilter.upsample(small, scale: scale, to: extent)
        return KernelLibrary.color("clarity_apply").apply(extent: extent, arguments: [image, upsampled, structure, Float(amount)]) ?? image
    }
}
