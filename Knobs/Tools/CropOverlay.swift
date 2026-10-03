import KnobsKit
import SwiftUI

/// The crop tool on the canvas: the crop rect over the whole straightened photo, darkened outside.
/// Drag a handle to resize, inside to move, outside to straighten. Double-click inside applies.
struct CropOverlay: View {
    let editor: EditorModel
    let settings: CropSettings
    let photoSize: CGSize
    /// Where the canvas draws the straightened photo; every point here maps through it.
    let layout: CanvasLayout
    let displayScale: CGFloat

    @State private var drag: Drag?

    private struct Drag {
        enum Kind {
            case move
            case resize(CropHandle)
            case straighten
        }

        let kind: Kind
        /// The crop as shown when the drag began, and the angle then.
        let rect: CGRect
        let angle: Double
    }

    private static let space = "crop"
    private static let corner: CGFloat = 22
    private static let edge: CGFloat = 14

    var body: some View {
        let geometry = settings.geometry(size: photoSize)
        let rect = settings.effectiveRect(size: photoSize)
        let frame = viewRect(crop: rect, geometry: geometry)
        ZStack(alignment: .topLeading) {
            OutsideShape(hole: frame)
                .fill(.black.opacity(0.6), style: FillStyle(eoFill: true))
                .contentShape(OutsideShape(hole: frame), eoFill: true)
                .gesture(gesture(kind: .straighten, rect: rect))

            Color.clear
                .contentShape(Rectangle())
                .frame(width: frame.width, height: frame.height)
                .offset(x: frame.minX, y: frame.minY)
                .pointerStyle(drag == nil ? .grabIdle : .grabActive)
                .onTapGesture(count: 2) { editor.commitCrop() }
                .gesture(gesture(kind: .move, rect: rect))

            GridLines(rect: frame, divisions: gridDivisions)
                .stroke(.white.opacity(0.45), lineWidth: 0.5)
                .allowsHitTesting(false)
            Rectangle()
                .stroke(.white.opacity(0.9), lineWidth: 1)
                .frame(width: frame.width, height: frame.height)
                .offset(x: frame.minX, y: frame.minY)
                .allowsHitTesting(false)
            Grips(rect: frame)
                .stroke(.white, style: StrokeStyle(lineWidth: 3, lineCap: .square))
                .shadow(color: .black.opacity(0.5), radius: 1)
                .allowsHitTesting(false)

            ForEach(CropHandle.allCases, id: \.self) { handle in
                let area = hitArea(handle: handle, frame: frame)
                Color.clear
                    .contentShape(Rectangle())
                    .frame(width: area.width, height: area.height)
                    .offset(x: area.minX, y: area.minY)
                    .pointerStyle(.frameResize(position: handle.resizePosition))
                    .gesture(gesture(kind: .resize(handle), rect: rect))
            }

            if case .straighten = drag?.kind {
                Text(settings.angle.formatted(.number.precision(.fractionLength(2))) + "°")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.7), in: Capsule())
                    .fixedSize()
                    .position(x: frame.midX, y: max(frame.minY - 16, 12))
                    .allowsHitTesting(false)
            }
        }
        .coordinateSpace(.named(Self.space))
        .overlay(alignment: .bottom) { actions }
        .onChange(of: settings.aspect) { old, _ in
            editor.cropAspectChanged(from: old)
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button("Reset") {
                if let crop = editor.cropPlugin { editor.reset(plugin: crop) }
            }
            Button("Cancel") { editor.cancelCrop() }
                .keyboardShortcut(.cancelAction)
                .help("Cancel (Esc)")
            Button("Done") { editor.commitCrop() }
                .keyboardShortcut(.defaultAction)
                .help("Apply (Return)")
        }
        .controlSize(.small)
        .padding(6)
        .background(.regularMaterial, in: Capsule())
        .padding(.bottom, 6)
    }

    /// Thirds while moving or resizing; a finer grid while straightening, to line up horizons.
    private var gridDivisions: Int {
        switch drag?.kind {
        case nil: 0
        case .straighten: 8
        case .move, .resize: 3
        }
    }

    private func gesture(kind: Drag.Kind, rect: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.space))
            .onChanged { value in
                let start = drag ?? Drag(kind: kind, rect: rect, angle: settings.angle)
                drag = start
                update(start: start, from: value.startLocation, to: value.location)
            }
            .onEnded { _ in drag = nil }
    }

    private func update(start: Drag, from: CGPoint, to: CGPoint) {
        let geometry = CropGeometry(size: photoSize, angle: start.angle)
        let before = cropPoint(view: from, geometry: geometry)
        let after = cropPoint(view: to, geometry: geometry)
        let delta = CGVector(dx: after.x - before.x, dy: after.y - before.y)
        switch start.kind {
        case .move:
            editor.setCrop(rect: geometry.moved(rect: start.rect, by: delta))
        case .resize(let handle):
            let ratio = settings.aspect.ratio(size: photoSize, rect: start.rect)
            editor.setCrop(rect: geometry.resized(rect: start.rect, handle: handle, by: delta, ratio: ratio))
        case .straighten:
            let pivot = layout.viewPoint(unit: CGPoint(x: 0.5, y: 0.5), pixelsPerPoint: displayScale)
            editor.setCrop(angle: CropGeometry.straightened(angle: start.angle, from: from, to: to, around: pivot))
        }
    }

    // MARK: Mapping

    private func viewPoint(crop point: CGPoint, geometry: CropGeometry) -> CGPoint {
        layout.viewPoint(unit: geometry.boundingPoint(point), pixelsPerPoint: displayScale)
    }

    private func cropPoint(view point: CGPoint, geometry: CropGeometry) -> CGPoint {
        geometry.cropPoint(bounding: layout.unitPoint(view: point, pixelsPerPoint: displayScale))
    }

    private func viewRect(crop rect: CGRect, geometry: CropGeometry) -> CGRect {
        let topLeft = viewPoint(crop: CGPoint(x: rect.minX, y: rect.minY), geometry: geometry)
        let bottomRight = viewPoint(crop: CGPoint(x: rect.maxX, y: rect.maxY), geometry: geometry)
        return CGRect(x: topLeft.x, y: topLeft.y, width: bottomRight.x - topLeft.x, height: bottomRight.y - topLeft.y)
    }

    /// Corners get a square grip; edges get the strip between them, so any point along an edge drags it.
    private func hitArea(handle: CropHandle, frame: CGRect) -> CGRect {
        let corner = Self.corner
        let edge = Self.edge
        let x: (Int) -> CGFloat = { [frame.minX, frame.midX, frame.maxX][$0 + 1] }
        let y: (Int) -> CGFloat = { [frame.minY, frame.midY, frame.maxY][$0 + 1] }
        if handle.isCorner {
            return CGRect(x: x(handle.horizontal) - corner / 2, y: y(handle.vertical) - corner / 2, width: corner, height: corner)
        }
        if handle.horizontal == 0 {
            let length = max(frame.width - corner, 0)
            return CGRect(x: frame.midX - length / 2, y: y(handle.vertical) - edge / 2, width: length, height: edge)
        }
        let length = max(frame.height - corner, 0)
        return CGRect(x: x(handle.horizontal) - edge / 2, y: frame.midY - length / 2, width: edge, height: length)
    }
}

/// The canvas minus the crop rect, filled even-odd.
private nonisolated struct OutsideShape: Shape {
    let hole: CGRect

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addRect(rect)
        path.addRect(hole)
        return path
    }
}

private nonisolated struct GridLines: Shape {
    let rect: CGRect
    let divisions: Int

    func path(in _: CGRect) -> Path {
        var path = Path()
        guard divisions > 1 else { return path }
        for index in 1..<divisions {
            let fraction = CGFloat(index) / CGFloat(divisions)
            let x = rect.minX + rect.width * fraction
            let y = rect.minY + rect.height * fraction
            path.move(to: CGPoint(x: x, y: rect.minY))
            path.addLine(to: CGPoint(x: x, y: rect.maxY))
            path.move(to: CGPoint(x: rect.minX, y: y))
            path.addLine(to: CGPoint(x: rect.maxX, y: y))
        }
        return path
    }
}

/// L-shaped corner grips and short bars at the edge midpoints, drawn just inside the rect.
private nonisolated struct Grips: Shape {
    let rect: CGRect

    func path(in _: CGRect) -> Path {
        var path = Path()
        let arm = min(16, rect.width / 3, rect.height / 3)
        let inset: CGFloat = 1.5
        let frame = rect.insetBy(dx: inset, dy: inset)
        for (corner, dx, dy) in [
            (CGPoint(x: frame.minX, y: frame.minY), 1.0, 1.0),
            (CGPoint(x: frame.maxX, y: frame.minY), -1.0, 1.0),
            (CGPoint(x: frame.minX, y: frame.maxY), 1.0, -1.0),
            (CGPoint(x: frame.maxX, y: frame.maxY), -1.0, -1.0),
        ] {
            path.move(to: CGPoint(x: corner.x + arm * dx, y: corner.y))
            path.addLine(to: corner)
            path.addLine(to: CGPoint(x: corner.x, y: corner.y + arm * dy))
        }
        let bar = arm / 2
        path.move(to: CGPoint(x: frame.midX - bar, y: frame.minY))
        path.addLine(to: CGPoint(x: frame.midX + bar, y: frame.minY))
        path.move(to: CGPoint(x: frame.midX - bar, y: frame.maxY))
        path.addLine(to: CGPoint(x: frame.midX + bar, y: frame.maxY))
        path.move(to: CGPoint(x: frame.minX, y: frame.midY - bar))
        path.addLine(to: CGPoint(x: frame.minX, y: frame.midY + bar))
        path.move(to: CGPoint(x: frame.maxX, y: frame.midY - bar))
        path.addLine(to: CGPoint(x: frame.maxX, y: frame.midY + bar))
        return path
    }
}

private extension CropHandle {
    var resizePosition: FrameResizePosition {
        switch self {
        case .topLeft: .topLeading
        case .top: .top
        case .topRight: .topTrailing
        case .right: .trailing
        case .bottomRight: .bottomTrailing
        case .bottom: .bottom
        case .bottomLeft: .bottomLeading
        case .left: .leading
        }
    }
}
