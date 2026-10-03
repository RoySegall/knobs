import CoreImage

/// Lightroom's graduated filter: its own exposure, tone, color and presence, faded across a line.
/// Runs after the crop, so the gradient sits where it is drawn on the cropped frame.
public struct GraduatedFilterPlugin: KnobPlugin {
    public let id = "graduated_filter"
    public let title = "Graduated Filter"
    public let panel = Panel(id: "graduated", title: "Graduated Filter", order: 65)
    public let stage = Stage.effects
    public let order = 5
    public let params: [KnobParam] = [
        .slider(id: "exposure", title: "Exposure", range: -4...4, decimals: 2),
        .slider(id: "contrast", title: "Contrast", range: -100...100),
        .slider(id: "highlights", title: "Highlights", range: -100...100),
        .slider(id: "shadows", title: "Shadows", range: -100...100),
        .slider(id: "temp", title: "Temp", range: -100...100, track: .gradient([
            KnobColor(red: 0.25, green: 0.45, blue: 0.95), KnobColor(red: 0.95, green: 0.85, blue: 0.25),
        ])),
        .slider(id: "tint", title: "Tint", range: -100...100, track: .gradient([
            KnobColor(red: 0.3, green: 0.8, blue: 0.3), KnobColor(red: 0.85, green: 0.3, blue: 0.8),
        ])),
        .slider(id: "saturation", title: "Saturation", range: -100...100),
        .slider(id: "clarity", title: "Clarity", range: -100...100),
        .slider(id: "dehaze", title: "Dehaze", range: -100...100),
        .slider(id: GraduatedGradient.Key.startX, title: "Start X", range: -0.5...1.5, default: 0.5, decimals: 3, presentation: .hidden),
        .slider(id: GraduatedGradient.Key.startY, title: "Start Y", range: -0.5...1.5, default: 0, decimals: 3, presentation: .hidden),
        .slider(id: GraduatedGradient.Key.endX, title: "End X", range: -0.5...1.5, default: 0.5, decimals: 3, presentation: .hidden),
        .slider(id: GraduatedGradient.Key.endY, title: "End Y", range: -0.5...1.5, default: 0.45, decimals: 3, presentation: .hidden),
    ]

    /// Each adjustment is the global plugin's own look, keyed by this plugin's param → that plugin's param.
    static let adjustments: [(plugin: any KnobPlugin, params: [String: String])] = [
        (WhiteBalancePlugin(), ["temp": "temp", "tint": "tint"]),
        (ExposurePlugin(), ["exposure": "exposure"]),
        (ContrastPlugin(), ["contrast": "contrast"]),
        (TonePlugin(), ["highlights": "highlights", "shadows": "shadows"]),
        (DehazePlugin(), ["dehaze": "amount"]),
        (ClarityPlugin(), ["clarity": "amount"]),
        (SaturationPlugin(), ["saturation": "saturation"]),
    ]

    public init() {}

    public func apply(image: CIImage, values: KnobValues, context: RenderContext) -> CIImage {
        let adjusted = Self.adjustments.reduce(image) { image, adjustment in
            let stored = adjustment.params.reduce(into: [String: KnobValue]()) { stored, pair in
                let amount = values.number(pair.key)
                if amount != 0 { stored[pair.value] = .number(amount) }
            }
            guard !stored.isEmpty else { return image }
            let plugin = adjustment.plugin
            return plugin.apply(image: image, values: KnobValues(params: plugin.params, stored: stored), context: context)
        }
        guard adjusted !== image else { return image }
        let mask = GraduatedGradient(values: values).mask(extent: image.extent)
        return adjusted
            .applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: image, kCIInputMaskImageKey: mask])
            .cropped(to: image.extent)
    }
}

/// The gradient's two ends as fractions of the frame, top-left origin: full effect at `start`, none at `end`.
public struct GraduatedGradient: Sendable, Equatable {
    public enum Key {
        public static let startX = "start_x"
        public static let startY = "start_y"
        public static let endX = "end_x"
        public static let endY = "end_y"
    }

    public var start: CGPoint
    public var end: CGPoint

    public init(start: CGPoint, end: CGPoint) {
        self.start = start
        self.end = end
    }

    public init(values: KnobValues) {
        start = CGPoint(x: values.number(Key.startX), y: values.number(Key.startY))
        end = CGPoint(x: values.number(Key.endX), y: values.number(Key.endY))
    }

    public var values: [String: KnobValue] {
        [
            Key.startX: .number(Self.rounded(start.x)),
            Key.startY: .number(Self.rounded(start.y)),
            Key.endX: .number(Self.rounded(end.x)),
            Key.endY: .number(Self.rounded(end.y)),
        ]
    }

    /// White before the start line, black past the end line, smoothstep between.
    func mask(extent: CGRect) -> CIImage {
        func point(_ unit: CGPoint) -> CIVector {
            CIVector(x: extent.minX + unit.x * extent.width, y: extent.maxY - unit.y * extent.height)
        }
        let from = point(start)
        var to = point(end)
        // Coincident ends would divide by zero; a one-pixel nudge keeps it a hard edge.
        if hypot(to.x - from.x, to.y - from.y) < 1 {
            to = CIVector(x: from.x + 1, y: from.y)
        }
        return CIImage.empty().applyingFilter("CISmoothLinearGradient", parameters: [
            "inputPoint0": from,
            "inputPoint1": to,
            "inputColor0": CIColor.white,
            "inputColor1": CIColor.black,
        ]).cropped(to: extent)
    }

    /// Three decimals: finer than a pixel on any screen, and the sidecar stays readable.
    private static func rounded(_ value: CGFloat) -> Double {
        (Double(value) * 1000).rounded() / 1000
    }
}
