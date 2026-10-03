import KnobsKit
import SwiftUI

/// Placeholder: a wheel as two sliders. The color-grading plugin replaces this with a real wheel.
struct WheelControl: View {
    let param: KnobParam
    @Binding var wheel: Wheel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(param.title).font(.system(size: 11, weight: .medium))
            KnobSlider(
                title: "Hue",
                slider: KnobParam.Slider(range: 0...360, defaultValue: 0, decimals: 0, unit: "°", track: .neutral),
                value: $wheel.hue
            )
            KnobSlider(
                title: "Saturation",
                slider: KnobParam.Slider(range: 0...1, defaultValue: 0, decimals: 2, unit: nil, track: .neutral),
                value: $wheel.amount
            )
        }
    }
}
