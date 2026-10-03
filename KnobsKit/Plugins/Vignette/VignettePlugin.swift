import CoreImage

/// Post-crop vignette in Lightroom's Highlight Priority style. Runs after geometry, so it follows the crop.
public struct VignettePlugin: KnobPlugin {
    public let id = "vignette"
    public let title = "Vignette"
    public let panel = Panel.effects
    public let stage = Stage.effects
    public let order = 10
    public let params: [KnobParam] = [
        .slider(id: "amount", title: "Amount", range: -100...100),
        .slider(id: "midpoint", title: "Midpoint", range: 0...100, default: 50),
        .slider(id: "roundness", title: "Roundness", range: -100...100),
        .slider(id: "feather", title: "Feather", range: 0...100, default: 50),
        .slider(id: "highlights", title: "Highlights", range: 0...100),
    ]

    public init() {}

    public func apply(image: CIImage, values: KnobValues, context: RenderContext) -> CIImage {
        let amount = values.number("amount") / 100
        let extent = image.extent
        guard amount != 0, !extent.isInfinite, extent.width >= 1, extent.height >= 1 else { return image }

        let half = CGSize(width: extent.width / 2, height: extent.height / 2)
        let roundness = values.number("roundness") / 100
        // Positive roundness bends the frame-shaped ellipse toward a circle; negative squares it off.
        let circle = max(roundness, 0)
        let longest = max(half.width, half.height)
        let axisX = 1 + (half.width / longest - 1) * circle
        let axisY = 1 + (half.height / longest - 1) * circle
        let exponent = 2 + 8 * max(-roundness, 0)
        let shape = CIVector(x: axisX, y: axisY, z: exponent, w: 1 / (pow(axisX, exponent) + pow(axisY, exponent)))

        let midpoint = values.number("midpoint") / 100
        let feather = values.number("feather") / 100
        let center = 0.3 + 0.8 * midpoint - 0.2 * midpoint * midpoint
        // At zero feather the edge still spans about a pixel, so it never aliases.
        let width = 0.4 * feather + 1 / min(half.width, half.height)

        return KernelLibrary.color("vignette_apply").apply(extent: extent, arguments: [
            image,
            CIVector(x: extent.midX, y: extent.midY, z: half.width, w: half.height),
            shape,
            CIVector(x: center - width, y: center + width),
            Float(amount),
            Float(values.number("highlights") / 100),
        ]) ?? image
    }
}
