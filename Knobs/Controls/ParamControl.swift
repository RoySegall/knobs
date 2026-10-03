import KnobsKit
import SwiftUI

/// Picks the control for a param's kind. A new kind needs a case here and a control beside it.
struct ParamControl: View {
    let param: KnobParam
    @Binding var value: KnobValue

    var body: some View {
        switch param.kind {
        case .slider(let slider):
            KnobSlider(
                title: param.title,
                slider: slider,
                value: Binding(
                    get: { if case .number(let number) = value { number } else { slider.defaultValue } },
                    set: { value = .number($0) }
                )
            )
        case .flag(let defaultValue):
            Toggle(
                param.title,
                isOn: Binding(
                    get: { if case .flag(let flag) = value { flag } else { defaultValue } },
                    set: { value = .flag($0) }
                )
            )
            .toggleStyle(.checkbox)
            .font(.system(size: 11))
        case .choice(let options, let defaultValue):
            Picker(
                param.title,
                selection: Binding(
                    get: { if case .choice(let choice) = value { choice } else { defaultValue } },
                    set: { value = .choice($0) }
                )
            ) {
                ForEach(options) { Text($0.title).tag($0.id) }
            }
            .font(.system(size: 11))
        case .curve(let defaultPoints):
            CurveEditor(
                param: param,
                points: Binding(
                    get: { if case .curve(let points) = value { points } else { defaultPoints } },
                    set: { value = .curve($0) }
                )
            )
        case .wheel(let defaultWheel):
            WheelControl(
                param: param,
                wheel: Binding(
                    get: { if case .wheel(let wheel) = value { wheel } else { defaultWheel } },
                    set: { value = .wheel($0) }
                )
            )
        }
    }
}
