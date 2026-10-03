import CoreImage

/// Lightroom's HSL mixer: hue, saturation and luminance for eight overlapping hue bands, in OKLCh.
public struct ColorMixerPlugin: KnobPlugin {
    struct Band {
        let id: String
        let title: String
        /// Where Lightroom puts the band, as an HSV hue.
        let wheelHue: Double
    }

    enum Channel: String, CaseIterable {
        case hue
        case saturation
        case luminance

        var title: String {
            rawValue.capitalized
        }
    }

    static let bands = [
        Band(id: "red", title: "Red", wheelHue: 0),
        Band(id: "orange", title: "Orange", wheelHue: 30),
        Band(id: "yellow", title: "Yellow", wheelHue: 60),
        Band(id: "green", title: "Green", wheelHue: 120),
        Band(id: "aqua", title: "Aqua", wheelHue: 180),
        Band(id: "blue", title: "Blue", wheelHue: 240),
        Band(id: "purple", title: "Purple", wheelHue: 270),
        Band(id: "magenta", title: "Magenta", wheelHue: 300),
    ]

    /// Band centers as OKLab hue angles, ascending.
    static let centers = bands.map { ColorOKLab.hue(wheelHue: $0.wheelHue) }

    /// log2 of the lightness gain at ±100.
    static let luminanceStops = 0.5

    public let id = "color_mixer"
    public let title = "Color Mixer"
    public let panel = Panel.mixer
    public let stage = Stage.color
    public let order = 30
    public let params: [KnobParam] = ColorMixerPlugin.makeParams()

    public init() {}

    public func apply(image: CIImage, values: KnobValues, context: RenderContext) -> CIImage {
        func amounts(_ channel: Channel) -> [Double] {
            Self.paramIDs[channel, default: []].map { values.number($0) / 100 }
        }
        let hue = amounts(.hue)
        let saturation = amounts(.saturation)
        let luminance = amounts(.luminance)
        guard (hue + saturation + luminance).contains(where: { $0 != 0 }) else { return image }

        let shifts = hue.indices.map { index in hue[index] * Self.reach(band: index, toward: hue[index]) }
        let stops = luminance.map { $0 * Self.luminanceStops }
        let arguments: [Any] = [image] + [Self.centers, shifts, saturation, stops].flatMap(Self.vectors)
        return KernelLibrary.color("color_mixer_apply").apply(extent: image.extent, arguments: arguments) ?? image
    }

    private static let paramIDs = Dictionary(uniqueKeysWithValues: Channel.allCases.map { channel in
        (channel, bands.map { paramID(band: $0, channel: channel) })
    })

    static func paramID(band: Band, channel: Channel) -> String {
        "\(band.id)_\(channel.rawValue)"
    }

    /// Degrees a band's center moves at ±100. Capped by both gaps so the hue mapping between neighbors
    /// neither squeezes below 0.4 nor stretches past 2 (smoothstep's steepest slope is 1.5 per gap).
    static func reach(band index: Int, toward amount: Double) -> Double {
        let count = centers.count
        let next = (index + 1) % count
        let previous = (index + count - 1) % count
        let gapAhead = gap(from: index, to: amount >= 0 ? next : previous)
        let gapBehind = gap(from: index, to: amount >= 0 ? previous : next)
        return min(0.4 * gapAhead, gapBehind / 1.5)
    }

    private static func gap(from first: Int, to second: Int) -> Double {
        let distance = abs(centers[first] - centers[second])
        return min(distance, 360 - distance)
    }

    private static func vectors(_ values: [Double]) -> [CIVector] {
        [CIVector(x: values[0], y: values[1], z: values[2], w: values[3]),
         CIVector(x: values[4], y: values[5], z: values[6], w: values[7])]
    }

    /// All hues, then all saturations, then all luminances, like Lightroom's tabs.
    private static func makeParams() -> [KnobParam] {
        Channel.allCases.flatMap { channel in
            bands.indices.map { index in
                let band = bands[index]
                return KnobParam.slider(
                    id: paramID(band: band, channel: channel),
                    title: "\(band.title) \(channel.title)",
                    range: -100...100,
                    track: track(band: index, channel: channel)
                )
            }
        }
    }

    /// Each slider's track shows its effect on the band's color.
    private static func track(band index: Int, channel: Channel) -> Track {
        let center = centers[index]
        let lightness = min(max(bandLightness[index], 0.62), 0.86)
        switch channel {
        case .hue:
            let left = reach(band: index, toward: -1)
            let right = reach(band: index, toward: 1)
            return .gradient((0...6).map { step in
                let position = Double(step) / 6
                let hue = center - left + (left + right) * position
                return ColorOKLab.swatch(lightness: lightness, chroma: 0.13, hue: hue)
            })
        case .saturation:
            return .gradient([
                ColorOKLab.swatch(lightness: lightness, chroma: 0, hue: center),
                ColorOKLab.swatch(lightness: lightness, chroma: 0.16, hue: center),
            ])
        case .luminance:
            return .gradient([
                ColorOKLab.swatch(lightness: 0.3, chroma: 0.07, hue: center),
                ColorOKLab.swatch(lightness: lightness, chroma: 0.12, hue: center),
                ColorOKLab.swatch(lightness: 0.95, chroma: 0.05, hue: center),
            ])
        }
    }

    /// OKLab lightness of each band's fully saturated color, so yellow's track is not drawn olive.
    private static let bandLightness = bands.map { band in
        ColorOKLab.lightness(wheelHue: band.wheelHue)
    }
}
