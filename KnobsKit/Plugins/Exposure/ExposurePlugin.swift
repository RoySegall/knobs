import CoreImage

/// Exposure in stops. On RAW it moves the decoder's exposure so highlights recover from sensor data;
/// on bitmaps a push rolls the top into white instead of clipping each channel.
public struct ExposurePlugin: KnobPlugin {
    public let id = "exposure"
    public let title = "Exposure"
    public let panel = Panel.light
    public let stage = Stage.raw
    public let order = 10
    public let params: [KnobParam] = [
        .slider(id: "exposure", title: "Exposure", range: -5...5, decimals: 2),
    ]

    public init() {}

    public func configure(raw: CIRAWFilter, values: KnobValues, context: RenderContext) -> Bool {
        raw.exposure += Float(values.number("exposure"))
        return true
    }

    public func apply(image: CIImage, values: KnobValues, context: RenderContext) -> CIImage {
        let stops = Float(values.number("exposure"))
        return KernelLibrary.color("exposure_apply").apply(extent: image.extent, arguments: [image, stops]) ?? image
    }
}
