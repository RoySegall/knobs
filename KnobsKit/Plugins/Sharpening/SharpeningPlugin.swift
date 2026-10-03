import CoreImage

/// Lightroom-style capture sharpening: an unsharp mask on luma with halo control (Detail) and an edge mask (Masking).
public struct SharpeningPlugin: KnobPlugin {
    public let id = "sharpening"
    public let title = "Sharpening"
    public let panel = Panel.detail
    public let stage = Stage.detail
    public let order = 20
    public let params: [KnobParam] = [
        .slider(id: "amount", title: "Amount", range: 0...150),
        .slider(id: "radius", title: "Radius", range: 0.5...3, default: 1, decimals: 1),
        .slider(id: "detail", title: "Detail", range: 0...100, default: 25),
        .slider(id: "masking", title: "Masking", range: 0...100),
    ]

    /// Smallest blur that still means something on a pixel grid.
    static let minimumSigma = 0.6
    /// Widest blur the kernel's 7x7 window covers to two sigma; wider ones come from a separate blur pass.
    static let inlineSigma = 1.5

    public init() {}

    /// High-pass response of an unsharp mask with this Gaussian sigma, at 0.35 cycles per pixel.
    static func response(sigma: Double) -> Double {
        1 - exp(-2 * Double.pi * Double.pi * sigma * sigma * 0.35 * 0.35)
    }

    public func apply(image: CIImage, values: KnobValues, context: RenderContext) -> CIImage {
        let amount = values.number("amount") / 100
        let extent = image.extent
        guard amount > 0, !extent.isInfinite else { return image }

        // Below the minimum, blur wider and scale the high-pass so its response at 0.35 cycles per pixel
        // matches the true radius. The preview then keeps the downscaled export's look.
        let sigma = values.number("radius") * context.scale
        let blurSigma = max(sigma, Self.minimumSigma)
        let compensation = Self.response(sigma: sigma) / Self.response(sigma: blurSigma)
        let gain = 1.5 * amount * compensation

        // The texture threshold applies to the high-pass the export would see, hence the compensation.
        let detail = values.number("detail") / 100
        let texture = 0.015 * pow(1 - detail, 2) / compensation.squareRoot()
        let halo = pow(detail, 0.7)

        let masking = values.number("masking") / 100
        let threshold = 0.01 + 0.2 * masking * masking
        let edgeSigma = min(max(1.5 * context.scale, 1), Self.inlineSigma)
        let mask = masking > 0 ? CIVector(x: 0.25 * threshold, y: threshold, z: edgeSigma) : CIVector(x: 0, y: 0, z: 1)

        let inline = blurSigma <= Self.inlineSigma
        let blurred = inline
            ? CIImage(color: .clear)
            : (KernelLibrary.color("sharpening_luma").apply(extent: extent, arguments: [image]) ?? image)
                .clampedToExtent().applyingGaussianBlur(sigma: blurSigma)
        // Two sigma of the widest inline Gaussian, and at least the 3x3 the halo limiter reads.
        let reach = max(1, min(3, (2 * max(inline ? blurSigma : 0, masking > 0 ? edgeSigma : 0)).rounded(.up)))

        let bounds = CIVector(x: extent.minX, y: extent.minY, z: extent.maxX, w: extent.maxY)
        return KernelLibrary.general("sharpening_apply").apply(
            extent: extent,
            roiCallback: { _, rect in rect.insetBy(dx: -reach, dy: -reach) },
            arguments: [image.clampedToExtent(), blurred, bounds, Float(inline ? blurSigma : 0), Float(reach),
                        Float(gain), Float(texture), Float(halo), mask]
        ) ?? image
    }
}
