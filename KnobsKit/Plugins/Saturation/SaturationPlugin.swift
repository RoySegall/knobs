import CoreImage

/// Uniform saturation. -100 is monochrome at the original luminance; +100 doubles chroma, rolling off at the gamut edge.
public struct SaturationPlugin: KnobPlugin {
    public let id = "saturation"
    public let title = "Saturation"
    public let panel = Panel.color
    public let stage = Stage.color
    public let order = 20
    public let panelOrder = 30
    public let params: [KnobParam] = [
        .slider(id: "saturation", title: "Saturation", range: -100...100, track: SaturationPlugin.track),
    ]

    public init() {}

    public func apply(image: CIImage, values: KnobValues, context: RenderContext) -> CIImage {
        let amount = values.number("saturation") / 100
        guard amount != 0 else { return image }
        let gain = Float(1 + amount)
        return KernelLibrary.color("saturation_apply").apply(extent: image.extent, arguments: [image, gain]) ?? image
    }

    /// Gray on the left, vivid on the right, shared with vibrance.
    static let track: Track = .gradient((0...8).map { step in
        let position = Double(step) / 8
        return ColorOKLab.swatch(lightness: 0.68, chroma: 0.16 * position, hue: 20 + 300 * position)
    })
}
