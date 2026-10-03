import CoreImage

/// Saturation that boosts muted colors most, leaves vivid ones nearly alone and spares skin tones.
/// Negative values mute, vivid colors first, without reaching monochrome.
public struct VibrancePlugin: KnobPlugin {
    public let id = "vibrance"
    public let title = "Vibrance"
    public let panel = Panel.color
    public let stage = Stage.color
    public let order = 10
    public let panelOrder = 20
    public let params: [KnobParam] = [
        .slider(id: "vibrance", title: "Vibrance", range: -100...100, track: SaturationPlugin.track),
    ]

    public init() {}

    public func apply(image: CIImage, values: KnobValues, context: RenderContext) -> CIImage {
        let amount = Float(values.number("vibrance") / 100)
        guard amount != 0 else { return image }
        return KernelLibrary.color("vibrance_apply").apply(extent: image.extent, arguments: [image, amount]) ?? image
    }
}
