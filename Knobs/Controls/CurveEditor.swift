import KnobsKit
import SwiftUI

/// Placeholder: draws the curve without editing it. The tone-curve plugin replaces this.
struct CurveEditor: View {
    let param: KnobParam
    @Binding var points: [CurvePoint]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(param.title).font(.system(size: 11))
            Canvas { context, size in
                var path = Path()
                for (index, point) in points.enumerated() {
                    let location = CGPoint(x: point.x * size.width, y: (1 - point.y) * size.height)
                    if index == 0 { path.move(to: location) } else { path.addLine(to: location) }
                }
                context.stroke(path, with: .color(.white), lineWidth: 1.5)
            }
            .aspectRatio(1, contentMode: .fit)
            .background(Color(white: 0.18))
        }
    }
}
