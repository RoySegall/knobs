import KnobsKit
import SwiftUI

/// The graduated filter on the canvas: lines across the frame where the fade starts, is half way and ends.
/// Drag on the photo to draw a new one, a dot to move that end, the center pin to move the whole gradient.
struct GradientOverlay: View {
    let editor: EditorModel
    let gradient: GraduatedGradient
    let layout: CanvasLayout
    let displayScale: CGFloat

    @State private var drag: Drag?

    private struct Drag {
        enum Kind {
            case draw
            case start
            case end
            case move
        }

        let kind: Kind
        let gradient: GraduatedGradient
    }

    /// How close a press must land to a dot to grab it, in points.
    private static let grab: CGFloat = 12

    var body: some View {
        let frame = layout.viewFrame(pixelsPerPoint: displayScale)
        let start = view(gradient.start)
        let end = view(gradient.end)
        let middle = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        ZStack(alignment: .topLeading) {
            Color.clear
                .contentShape(Rectangle())
                .gesture(dragGesture(start: start, end: end, middle: middle))
            Canvas { context, _ in
                context.clip(to: Path(frame))
                let lines = Self.lines(start: start, end: end, length: hypot(frame.width, frame.height))
                for line in [lines.start, lines.end] {
                    context.stroke(line, with: .color(.black.opacity(0.45)), lineWidth: 3)
                    context.stroke(line, with: .color(.white), lineWidth: 1.5)
                }
                context.stroke(lines.middle, with: .color(.white.opacity(0.75)), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
            }
            .allowsHitTesting(false)
            dot(at: start, size: 9)
            dot(at: end, size: 9)
            pin(at: middle)
            Text("Drag to draw · drag a dot to adjust · G or Return when done")
                .font(.system(size: 11))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(.black.opacity(0.6), in: Capsule())
                .fixedSize()
                .position(x: frame.midX, y: frame.maxY - 18)
                .allowsHitTesting(false)
        }
    }

    private func dragGesture(start: CGPoint, end: CGPoint, middle: CGPoint) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if drag == nil {
                    drag = Drag(kind: kind(at: value.startLocation, start: start, end: end, middle: middle), gradient: gradient)
                }
                guard let drag else { return }
                let from = unit(value.startLocation)
                let to = unit(value.location)
                let delta = CGPoint(x: to.x - from.x, y: to.y - from.y)
                var next = drag.gradient
                switch drag.kind {
                case .draw:
                    next = GraduatedGradient(start: from, end: to)
                case .start:
                    next.start = Self.offset(drag.gradient.start, by: delta)
                case .end:
                    next.end = Self.offset(drag.gradient.end, by: delta)
                case .move:
                    next.start = Self.offset(drag.gradient.start, by: delta)
                    next.end = Self.offset(drag.gradient.end, by: delta)
                }
                editor.setGradient(next)
            }
            .onEnded { _ in drag = nil }
    }

    private func kind(at point: CGPoint, start: CGPoint, end: CGPoint, middle: CGPoint) -> Drag.Kind {
        let candidates: [(Drag.Kind, CGPoint)] = [(.start, start), (.end, end), (.move, middle)]
        let nearest = candidates.min { hypot($0.1.x - point.x, $0.1.y - point.y) < hypot($1.1.x - point.x, $1.1.y - point.y) }
        guard let nearest, hypot(nearest.1.x - point.x, nearest.1.y - point.y) <= Self.grab else { return .draw }
        return nearest.0
    }

    private func view(_ unit: CGPoint) -> CGPoint {
        layout.viewPoint(unit: unit, pixelsPerPoint: displayScale)
    }

    private func unit(_ view: CGPoint) -> CGPoint {
        layout.unitPoint(view: view, pixelsPerPoint: displayScale)
    }

    private func dot(at point: CGPoint, size: CGFloat) -> some View {
        Circle()
            .fill(.white)
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(0.6), radius: 1.5)
            .position(point)
            .allowsHitTesting(false)
    }

    private func pin(at point: CGPoint) -> some View {
        Circle()
            .fill(Color.accentColor)
            .frame(width: 12, height: 12)
            .overlay(Circle().stroke(.white, lineWidth: 2))
            .shadow(color: .black.opacity(0.6), radius: 1.5)
            .position(point)
            .allowsHitTesting(false)
    }

    private static func offset(_ point: CGPoint, by delta: CGPoint) -> CGPoint {
        CGPoint(x: point.x + delta.x, y: point.y + delta.y)
    }

    /// Lines perpendicular to start→end through the start, the middle and the end, `length` each way.
    static func lines(start: CGPoint, end: CGPoint, length: CGFloat) -> (start: Path, middle: Path, end: Path) {
        var direction = CGPoint(x: end.x - start.x, y: end.y - start.y)
        let distance = hypot(direction.x, direction.y)
        direction = distance < 0.5 ? CGPoint(x: 0, y: 1) : CGPoint(x: direction.x / distance, y: direction.y / distance)
        let normal = CGPoint(x: -direction.y * length, y: direction.x * length)
        func line(through point: CGPoint) -> Path {
            Path { path in
                path.move(to: CGPoint(x: point.x - normal.x, y: point.y - normal.y))
                path.addLine(to: CGPoint(x: point.x + normal.x, y: point.y + normal.y))
            }
        }
        let middle = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        return (line(through: start), line(through: middle), line(through: end))
    }
}
