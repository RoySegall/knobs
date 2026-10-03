import KnobsKit
import SwiftUI

/// Lightroom-style color wheel: hue around the rim, amount out from the neutral center.
/// Click or drag to place the puck; double-click resets.
struct WheelControl: View {
    let param: KnobParam
    @Binding var wheel: Wheel

    private static let diameter: CGFloat = 96

    private var defaultWheel: Wheel {
        if case .wheel(let wheel) = param.kind { wheel } else { Wheel(hue: 0, amount: 0) }
    }

    var body: some View {
        VStack(spacing: 4) {
            Text(param.title)
                .font(.system(size: 11))
            WheelDisc(wheel: $wheel, reset: { wheel = defaultWheel })
                .frame(width: Self.diameter, height: Self.diameter)
            Text(readout)
                .font(.system(size: 10))
                .monospacedDigit()
                .foregroundStyle(wheel.amount == 0 ? .secondary : .primary)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { wheel = defaultWheel }
        .help("Drag to tint, double-click to reset")
    }

    private var readout: String {
        "\(Int(wheel.hue.rounded()))°  ·  \(Int((wheel.amount * 100).rounded()))"
    }
}

private struct WheelDisc: View {
    @Binding var wheel: Wheel
    let reset: () -> Void

    /// Hue grows counterclockwise from red at three o'clock; SwiftUI's angular gradient runs clockwise.
    private static let rim = AngularGradient(
        colors: stride(from: 360, through: 0, by: -30).map { Color(hue: Double($0 % 360) / 360, saturation: 1, brightness: 1) },
        center: .center
    )

    var body: some View {
        GeometryReader { geometry in
            let radius = min(geometry.size.width, geometry.size.height) / 2
            let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
            ZStack {
                Circle().fill(Self.rim)
                Circle().fill(
                    RadialGradient(
                        colors: [Color(white: 0.42), Color(white: 0.42).opacity(0)],
                        center: .center,
                        startRadius: 0,
                        endRadius: radius
                    )
                )
                // Lightroom's wheels are muted so the puck, not the rim, draws the eye.
                Circle().fill(Color.black.opacity(0.25))
                Circle().stroke(Color.black.opacity(0.5), lineWidth: 1)
                Path { path in
                    path.move(to: CGPoint(x: center.x - 4, y: center.y))
                    path.addLine(to: CGPoint(x: center.x + 4, y: center.y))
                    path.move(to: CGPoint(x: center.x, y: center.y - 4))
                    path.addLine(to: CGPoint(x: center.x, y: center.y + 4))
                }
                .stroke(Color.white.opacity(0.35), lineWidth: 1)
                puck
                    .position(location(center: center, radius: radius))
            }
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { drag in
                    wheel = Self.wheel(at: drag.location, center: center, radius: radius, keeping: wheel.hue)
                }
            )
            .simultaneousGesture(TapGesture(count: 2).onEnded(reset))
        }
    }

    private var puck: some View {
        Circle()
            .fill(Color(hue: wheel.hue / 360, saturation: wheel.amount, brightness: 0.55 + 0.45 * wheel.amount))
            .frame(width: 11, height: 11)
            .overlay(Circle().stroke(.white, lineWidth: 1.5))
            .shadow(radius: 1)
    }

    private func location(center: CGPoint, radius: CGFloat) -> CGPoint {
        let angle = wheel.hue * .pi / 180
        let distance = radius * wheel.amount
        return CGPoint(x: center.x + distance * cos(angle), y: center.y - distance * sin(angle))
    }

    /// Hue in whole degrees, amount in hundredths; the center snaps to zero so neutral is easy to hit.
    private static func wheel(at point: CGPoint, center: CGPoint, radius: CGFloat, keeping hue: Double) -> Wheel {
        let dx = point.x - center.x
        let dy = center.y - point.y
        let amount = min((dx * dx + dy * dy).squareRoot() / max(radius, 1), 1)
        guard amount >= 0.04 else { return Wheel(hue: hue, amount: 0) }
        let degrees = (atan2(dy, dx) * 180 / .pi).rounded()
        return Wheel(hue: degrees < 0 ? degrees + 360 : degrees, amount: (amount * 100).rounded() / 100)
    }
}
