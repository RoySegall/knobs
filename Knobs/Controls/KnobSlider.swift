import KnobsKit
import SwiftUI

/// Lightroom-style slider: label and value on top, thin track below, double-click the label to reset.
struct KnobSlider: View {
    let title: String
    let slider: KnobParam.Slider
    @Binding var value: Double

    var body: some View {
        VStack(spacing: 3) {
            HStack {
                Text(title)
                Spacer()
                Text(formatted)
                    .monospacedDigit()
                    .foregroundStyle(value == slider.defaultValue ? .secondary : .primary)
            }
            .font(.system(size: 11))
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { value = slider.defaultValue }
            .help("Double-click to reset")
            SliderTrack(slider: slider, value: $value)
        }
    }

    private var formatted: String {
        let text = value.formatted(.number.precision(.fractionLength(slider.decimals)))
        let signed = slider.range.lowerBound < 0 && value > 0 ? "+" + text : text
        return slider.unit.map { "\(signed) \($0)" } ?? signed
    }
}

private struct SliderTrack: View {
    let slider: KnobParam.Slider
    @Binding var value: Double

    private var span: Double {
        slider.range.upperBound - slider.range.lowerBound
    }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let x = { (value: Double) in CGFloat((value - slider.range.lowerBound) / span) * width }
            ZStack(alignment: .leading) {
                track
                    .frame(height: 3)
                    .clipShape(Capsule())
                if case .neutral = slider.track {
                    let from = x(slider.defaultValue)
                    let to = x(value)
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: abs(to - from), height: 3)
                        .offset(x: min(from, to))
                }
                Circle()
                    .fill(.white)
                    .frame(width: 11, height: 11)
                    .shadow(radius: 1)
                    .offset(x: x(value) - 5.5)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { drag in
                    let fraction = min(max(drag.location.x / max(width, 1), 0), 1)
                    value = snapped(slider.range.lowerBound + Double(fraction) * span)
                }
            )
        }
        .frame(height: 14)
    }

    @ViewBuilder
    private var track: some View {
        switch slider.track {
        case .neutral:
            Capsule().fill(Color(white: 0.3))
        case .gradient(let colors):
            LinearGradient(
                colors: colors.map { Color(red: $0.red, green: $0.green, blue: $0.blue) },
                startPoint: .leading,
                endPoint: .trailing
            )
        }
    }

    /// Rounds to the displayed precision, and sticks to the default within 1% of the track.
    private func snapped(_ raw: Double) -> Double {
        if abs(raw - slider.defaultValue) < span * 0.01 {
            return slider.defaultValue
        }
        let factor = pow(10, Double(slider.decimals))
        return (raw * factor).rounded() / factor
    }
}
