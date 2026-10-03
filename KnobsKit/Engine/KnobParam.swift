import Foundation

public struct KnobParam: Sendable, Identifiable {
    public enum Kind: Sendable {
        case slider(Slider)
        case flag(default: Bool)
        case choice(options: [Choice], default: String)
        case curve(default: [CurvePoint])
        case wheel(default: Wheel)
    }

    public struct Slider: Sendable {
        public let range: ClosedRange<Double>
        public let defaultValue: Double
        public let decimals: Int
        public let unit: String?
        public let track: Track

        public init(range: ClosedRange<Double>, defaultValue: Double, decimals: Int, unit: String?, track: Track) {
            self.range = range
            self.defaultValue = defaultValue
            self.decimals = decimals
            self.unit = unit
            self.track = track
        }
    }

    public struct Choice: Sendable, Hashable, Identifiable {
        public let id: String
        public let title: String

        public init(id: String, title: String) {
            self.id = id
            self.title = title
        }
    }

    /// Where the control is drawn.
    public enum Presentation: Sendable {
        case inspector
        /// Driven by a custom tool (e.g. crop handles on the canvas), not the inspector.
        case hidden
    }

    public let id: String
    public let title: String
    public let kind: Kind
    public let presentation: Presentation

    public init(id: String, title: String, kind: Kind, presentation: Presentation = .inspector) {
        self.id = id
        self.title = title
        self.kind = kind
        self.presentation = presentation
    }

    public var defaultValue: KnobValue {
        switch kind {
        case .slider(let slider): .number(slider.defaultValue)
        case .flag(let value): .flag(value)
        case .choice(_, let value): .choice(value)
        case .curve(let points): .curve(points)
        case .wheel(let wheel): .wheel(wheel)
        }
    }

    /// The stored value when it fits this param, clamped to range; the default otherwise.
    public func resolve(_ stored: KnobValue?) -> KnobValue {
        switch (kind, stored) {
        case (.slider(let slider), .number(let value)?):
            .number(min(max(value, slider.range.lowerBound), slider.range.upperBound))
        case (.flag, .flag(let value)?):
            .flag(value)
        case (.choice(let options, _), .choice(let value)?) where options.contains(where: { $0.id == value }):
            .choice(value)
        case (.curve, .curve(let points)?) where points.count >= 2:
            .curve(points.sorted { $0.x < $1.x })
        case (.wheel, .wheel(let wheel)?):
            .wheel(Wheel(hue: wheel.hue, amount: min(max(wheel.amount, 0), 1)))
        default:
            defaultValue
        }
    }
}

extension KnobParam {
    public static func slider(
        id: String,
        title: String,
        range: ClosedRange<Double>,
        default defaultValue: Double = 0,
        decimals: Int = 0,
        unit: String? = nil,
        track: Track = .neutral,
        presentation: Presentation = .inspector
    ) -> KnobParam {
        KnobParam(
            id: id,
            title: title,
            kind: .slider(Slider(range: range, defaultValue: defaultValue, decimals: decimals, unit: unit, track: track)),
            presentation: presentation
        )
    }

    public static func flag(id: String, title: String, default defaultValue: Bool = false) -> KnobParam {
        KnobParam(id: id, title: title, kind: .flag(default: defaultValue))
    }

    public static func choice(id: String, title: String, options: [Choice], default defaultValue: String) -> KnobParam {
        KnobParam(id: id, title: title, kind: .choice(options: options, default: defaultValue))
    }

    public static func curve(id: String, title: String, default points: [CurvePoint] = CurvePoint.identity) -> KnobParam {
        KnobParam(id: id, title: title, kind: .curve(default: points))
    }

    public static func wheel(id: String, title: String, default wheel: Wheel = Wheel(hue: 0, amount: 0)) -> KnobParam {
        KnobParam(id: id, title: title, kind: .wheel(default: wheel))
    }
}

/// Background of a slider's track, e.g. blue to yellow for temperature.
public enum Track: Sendable, Hashable {
    case neutral
    case gradient([KnobColor])
}

/// sRGB-encoded display color, 0...1 per channel.
public struct KnobColor: Sendable, Hashable {
    public let red: Double
    public let green: Double
    public let blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }
}
