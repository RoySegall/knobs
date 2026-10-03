import CoreImage

/// Medium-fine detail: positive brings out texture, negative smooths it (skin) while edges and the
/// finest detail stay. Works on perceptual luminance, so tonality and color are left alone.
public struct TexturePlugin: KnobPlugin {
    public let id = "texture"
    public let title = "Texture"
    public let panel = Panel.presence
    public let stage = Stage.presence
    public let order = 10
    public let params: [KnobParam] = [
        .slider(id: "amount", title: "Texture", range: -100...100),
    ]

    /// Band edges as Gaussian sigmas in full-resolution pixels.
    static let fineSigma = 1.0
    static let coarseSigma = 3.0
    /// Local variance (sRGB-encoded luminance) at which a window counts half as edge, half as texture.
    static let edgeVariance: Float = 0.005

    public init() {}

    public func apply(image: CIImage, values: KnobValues, context: RenderContext) -> CIImage {
        let amount = values.number("amount") / 100
        guard amount != 0 else { return image }
        let extent = image.extent
        guard let moments = KernelLibrary.color("texture_moments").apply(extent: extent, arguments: [image]) else { return image }
        // Below half a pixel the fine blur is invisible at this resolution. The coarse blur continues from
        // the fine one: two blurs branching off one clamped source come back wrong along the borders.
        let fineSigma = Self.fineSigma * context.scale
        let coarseSigma = Self.coarseSigma * context.scale
        let blursFine = fineSigma >= 0.5
        let fine = blursFine ? blur(moments, sigma: fineSigma) : moments
        let coarse = blur(fine, sigma: blursFine ? (coarseSigma * coarseSigma - fineSigma * fineSigma).squareRoot() : coarseSigma)
        return KernelLibrary.color("texture_apply").apply(
            extent: extent,
            arguments: [image, fine, coarse, Float(amount), Self.edgeVariance]
        ) ?? image
    }

    private func blur(_ image: CIImage, sigma: Double) -> CIImage {
        image.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: image.extent)
    }
}
