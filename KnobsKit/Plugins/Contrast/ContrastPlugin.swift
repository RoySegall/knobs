import CoreImage

/// An S-curve around mid-gray in sRGB gamma. Black and white stay put; hue is preserved.
public struct ContrastPlugin: KnobPlugin {
    public let id = "contrast"
    public let title = "Contrast"
    public let panel = Panel.light
    public let stage = Stage.tone
    public let order = 20
    public let params: [KnobParam] = [
        .slider(id: "contrast", title: "Contrast", range: -100...100),
    ]

    public init() {}

    /// Curve slope at mid-gray: 2 at +100, 0.5 at -100, even steps in between.
    static func slope(amount: Double) -> Double {
        exp2(amount / 100)
    }

    public func apply(image: CIImage, values: KnobValues, context: RenderContext) -> CIImage {
        let amount = values.number("contrast")
        guard amount != 0 else { return image }
        let slope = Float(Self.slope(amount: amount))
        return KernelLibrary.color("contrast_apply").apply(extent: image.extent, arguments: [image, slope]) ?? image
    }
}
