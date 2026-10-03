import AppKit
import KnobsKit
import SwiftUI

/// Lightroom-style point curve. Several curve params (RGB, Red, Green, Blue) share one pad with a picker.
/// Drag a point to move it, press elsewhere to add one on the curve, double-click or drag it out to delete.
struct CurveEditor: View {
    struct Channel: Identifiable {
        let param: KnobParam
        let points: Binding<[CurvePoint]>

        init(param: KnobParam, value: Binding<KnobValue>) {
            self.param = param
            let fallback = param.defaultValue
            points = Binding(
                get: {
                    if case .curve(let points) = value.wrappedValue { return points }
                    if case .curve(let points) = fallback { return points }
                    return CurvePoint.identity
                },
                set: { value.wrappedValue = .curve($0) }
            )
        }

        var id: String { param.id }

        var color: Color {
            guard let tint = param.tint else { return Color(white: 0.92) }
            return Color(red: tint.red, green: tint.green, blue: tint.blue)
        }

        var isDefault: Bool {
            KnobValue.curve(points.wrappedValue) == param.defaultValue
        }
    }

    let channels: [Channel]
    @State private var selectedID: String?

    private var selected: Channel {
        channels.first { $0.id == selectedID } ?? channels[0]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if channels.count > 1 {
                Picker("Channel", selection: Binding(get: { selected.id }, set: { selectedID = $0 })) {
                    ForEach(channels) { channel in
                        Text(channel.isDefault ? channel.param.title : "\(channel.param.title) •").tag(channel.id)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
            } else {
                Text(selected.param.title).font(.system(size: 11))
            }
            CurvePad(channel: selected, backdrop: channels.filter { $0.id != selected.id && !$0.isDefault })
                .id(selected.id)
        }
    }
}

private struct CurvePad: View {
    let channel: CurveEditor.Channel
    /// Other edited channels, drawn faintly behind the active one.
    let backdrop: [CurveEditor.Channel]

    private enum Drag {
        case idle
        /// The press landed where no point can go; the rest of the gesture does nothing.
        case ignoring
        /// Each frame rebuilds the curve from `base`, so a point dragged out and back in returns.
        case moving(index: Int, origin: CurvePoint, base: [CurvePoint])
    }

    @State private var drag = Drag.idle
    @State private var hover: CGPoint?
    @State private var lastClick: (index: Int, time: TimeInterval)?

    /// Closest two points may sit horizontally, as a share of the width.
    private static let gap = 0.01
    private static let hitRadius: CGFloat = 7
    /// How far past the pad a dragged point must go to be deleted.
    private static let deleteMargin: CGFloat = 24

    var body: some View {
        GeometryReader { proxy in
            let plot = Plot(size: proxy.size)
            Canvas { context, _ in
                draw(in: &context, plot: plot)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if case .idle = drag {
                            begin(at: value.startLocation, plot: plot)
                        }
                        move(translation: value.translation, location: value.location, plot: plot)
                    }
                    .onEnded { value in
                        end(translation: value.translation)
                    }
            )
            .onContinuousHover { phase in
                switch phase {
                case .active(let location): hover = location
                case .ended: hover = nil
                }
            }
            .contextMenu {
                Button("Reset \(channel.param.title) Curve") {
                    if case .curve(let points) = channel.param.defaultValue {
                        channel.points.wrappedValue = points
                    }
                }
                .disabled(channel.isDefault)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .help("Drag to shape · click to add a point · double-click or drag out to remove")
    }

    // MARK: - Gesture

    private func begin(at location: CGPoint, plot: Plot) {
        let points = channel.points.wrappedValue
        if let index = hitIndex(at: location, points: points, plot: plot) {
            drag = .moving(index: index, origin: points[index], base: points)
            return
        }
        let x = min(max(plot.value(at: location).x, 0), 1)
        guard let insertion = points.firstIndex(where: { $0.x > x }), insertion > 0,
              x - points[insertion - 1].x >= Self.gap, points[insertion].x - x >= Self.gap
        else {
            drag = .ignoring
            return
        }
        let point = CurvePoint(x: x, y: MonotoneCurve(points: points).value(at: x))
        var base = points
        base.insert(point, at: insertion)
        channel.points.wrappedValue = base
        drag = .moving(index: insertion, origin: point, base: base)
    }

    private func move(translation: CGSize, location: CGPoint, plot: Plot) {
        guard case .moving(let index, let origin, let base) = drag else { return }
        let isEnd = index == 0 || index == base.count - 1
        var points = base
        if !isEnd, !plot.rect.insetBy(dx: -Self.deleteMargin, dy: -Self.deleteMargin).contains(location) {
            points.remove(at: index)
        } else {
            var x = origin.x + translation.width / plot.rect.width
            let y = min(max(origin.y - translation.height / plot.rect.height, 0), 1)
            // End points slide vertically only; the rest stay strictly between their neighbours.
            x = isEnd ? origin.x : min(max(x, base[index - 1].x + Self.gap), base[index + 1].x - Self.gap)
            points[index] = CurvePoint(x: x, y: y)
        }
        if points != channel.points.wrappedValue {
            channel.points.wrappedValue = points
        }
    }

    private func end(translation: CGSize) {
        defer { drag = .idle }
        guard case .moving(let index, _, let base) = drag, hypot(translation.width, translation.height) < 2 else {
            lastClick = nil
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        let isEnd = index == 0 || index == base.count - 1
        if let lastClick, lastClick.index == index, now - lastClick.time < NSEvent.doubleClickInterval, !isEnd {
            var points = base
            points.remove(at: index)
            channel.points.wrappedValue = points
            self.lastClick = nil
        } else {
            lastClick = (index, now)
        }
    }

    private func hitIndex(at location: CGPoint, points: [CurvePoint], plot: Plot) -> Int? {
        let distances = points.enumerated().map { index, point in
            (index: index, distance: hypot(plot.location(of: point).x - location.x, plot.location(of: point).y - location.y))
        }
        guard let nearest = distances.min(by: { $0.distance < $1.distance }), nearest.distance <= Self.hitRadius else { return nil }
        return nearest.index
    }

    // MARK: - Drawing

    private func draw(in context: inout GraphicsContext, plot: Plot) {
        let rect = plot.rect
        context.fill(Path(roundedRect: CGRect(origin: .zero, size: plot.size), cornerRadius: 4), with: .color(Color(white: 0.16)))

        var grid = Path()
        for quarter in [0.25, 0.5, 0.75] {
            grid.move(to: plot.location(x: quarter, y: 0))
            grid.addLine(to: plot.location(x: quarter, y: 1))
            grid.move(to: plot.location(x: 0, y: quarter))
            grid.addLine(to: plot.location(x: 1, y: quarter))
        }
        context.stroke(grid, with: .color(.white.opacity(0.07)), lineWidth: 1)
        context.stroke(Path(rect), with: .color(.white.opacity(0.12)), lineWidth: 1)

        var diagonal = Path()
        diagonal.move(to: plot.location(x: 0, y: 0))
        diagonal.addLine(to: plot.location(x: 1, y: 1))
        context.stroke(diagonal, with: .color(.white.opacity(0.18)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

        for other in backdrop {
            context.stroke(curvePath(other.points.wrappedValue, plot: plot), with: .color(other.color.opacity(0.35)), lineWidth: 1)
        }

        let points = channel.points.wrappedValue
        context.stroke(curvePath(points, plot: plot), with: .color(channel.color), lineWidth: 1.5)

        let active = activeIndex(points: points, plot: plot)
        for (index, point) in points.enumerated() {
            let center = plot.location(of: point)
            let radius: CGFloat = index == active ? 4.5 : 3.5
            let dot = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            context.fill(dot, with: .color(channel.color))
            if index == active {
                context.stroke(dot, with: .color(.white), lineWidth: 1)
            }
        }

        if let readout = readout(points: points, plot: plot) {
            context.draw(
                Text(readout).font(.system(size: 10).monospacedDigit()).foregroundStyle(.white.opacity(0.6)),
                at: CGPoint(x: rect.minX + 5, y: rect.minY + 4),
                anchor: .topLeading
            )
        }
    }

    private func curvePath(_ points: [CurvePoint], plot: Plot) -> Path {
        let samples = max(Int(plot.rect.width), 2)
        let xs = (0...samples).map { Double($0) / Double(samples) }
        let ys = MonotoneCurve(points: points).values(at: xs)
        var path = Path()
        path.addLines(zip(xs, ys).map { plot.location(x: $0, y: $1) })
        return path
    }

    /// The point being dragged, or else the one under the pointer.
    private func activeIndex(points: [CurvePoint], plot: Plot) -> Int? {
        if case .moving(let index, _, let base) = drag {
            return points.count == base.count ? index : nil
        }
        return hover.flatMap { hitIndex(at: $0, points: points, plot: plot) }
    }

    /// Input and output in percent: of the dragged point, or of the curve under the pointer.
    private func readout(points: [CurvePoint], plot: Plot) -> String? {
        let value: (x: Double, y: Double)
        if case .moving(let index, _, let base) = drag {
            guard points.count == base.count else { return nil }
            value = (points[index].x, points[index].y)
        } else if let hover, plot.rect.contains(hover) {
            let x = plot.value(at: hover).x
            value = (x, MonotoneCurve(points: points).value(at: x))
        } else {
            return nil
        }
        return "\(Int((value.x * 100).rounded())) → \(Int((value.y * 100).rounded()))"
    }
}

/// Maps curve space (0...1, y up) to the pad, inset so the end points' handles are not clipped.
private struct Plot {
    let size: CGSize
    let rect: CGRect

    init(size: CGSize) {
        self.size = size
        rect = CGRect(origin: .zero, size: size).insetBy(dx: 6, dy: 6)
    }

    func location(x: Double, y: Double) -> CGPoint {
        CGPoint(x: rect.minX + x * rect.width, y: rect.maxY - y * rect.height)
    }

    func location(of point: CurvePoint) -> CGPoint {
        location(x: point.x, y: point.y)
    }

    func value(at location: CGPoint) -> (x: Double, y: Double) {
        ((location.x - rect.minX) / rect.width, (rect.maxY - location.y) / rect.height)
    }
}
