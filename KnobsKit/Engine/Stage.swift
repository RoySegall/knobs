import CoreGraphics

/// Where a plugin runs. The order is fixed, like Lightroom's process order.
public enum Stage: Int, Sendable, CaseIterable, Comparable {
    /// RAW decoder settings (white balance, exposure). Non-RAW files run these through `apply`.
    case raw
    /// Scene-linear work before tone shaping (dehaze).
    case scene
    case tone
    case presence
    case color
    case detail
    /// Changes the frame. Runs before effects so vignette and grain follow the crop.
    case geometry
    case effects

    public static func < (lhs: Stage, rhs: Stage) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// An inspector section. Plugins may declare their own; the built-ins mirror Lightroom's Develop module.
public struct Panel: Sendable, Hashable, Identifiable {
    public let id: String
    public let title: String
    public let order: Int

    public init(id: String, title: String, order: Int) {
        self.id = id
        self.title = title
        self.order = order
    }

    public static let light = Panel(id: "light", title: "Light", order: 10)
    public static let color = Panel(id: "color", title: "Color", order: 20)
    public static let presence = Panel(id: "presence", title: "Presence", order: 30)
    public static let curve = Panel(id: "curve", title: "Tone Curve", order: 40)
    public static let mixer = Panel(id: "mixer", title: "Color Mixer", order: 50)
    public static let grading = Panel(id: "grading", title: "Color Grading", order: 60)
    public static let detail = Panel(id: "detail", title: "Detail", order: 70)
    public static let effects = Panel(id: "effects", title: "Effects", order: 80)
    public static let geometry = Panel(id: "geometry", title: "Crop & Straighten", order: 90)
}

public struct RenderContext: Sendable {
    public enum Source: Sendable {
        case raw
        case bitmap
    }

    /// Rendered pixels per full-resolution pixel. Multiply radii by this so the preview matches the export.
    public let scale: Double
    /// Full-resolution size of the oriented photo.
    public let fullSize: CGSize
    public let source: Source

    public init(scale: Double, fullSize: CGSize, source: Source) {
        self.scale = scale
        self.fullSize = fullSize
        self.source = source
    }
}
