import KnobsKit
import SwiftUI

/// One inspector row: a lone param, or every param sharing a `group`, placed where the first of them sits.
enum ParamRow: Identifiable {
    case single(KnobParam)
    case group(id: String, params: [KnobParam])

    var id: String {
        switch self {
        case .single(let param): "param.\(param.id)"
        case .group(let id, _): "group.\(id)"
        }
    }

    static func rows(for params: [KnobParam]) -> [ParamRow] {
        var rows: [ParamRow] = []
        for param in params {
            guard let group = param.group else {
                rows.append(.single(param))
                continue
            }
            if let index = rows.firstIndex(where: { $0.id == "group.\(group)" }), case .group(_, let members) = rows[index] {
                rows[index] = .group(id: group, params: members + [param])
            } else {
                rows.append(.group(id: group, params: [param]))
            }
        }
        return rows
    }
}

/// Draws a param group as one control. Curves share one editor with a picker; other kinds simply stack.
struct ParamGroupControl: View {
    let params: [KnobParam]
    let value: (KnobParam) -> Binding<KnobValue>

    var body: some View {
        if params.allSatisfy({ if case .curve = $0.kind { true } else { false } }) {
            CurveEditor(channels: params.map { CurveEditor.Channel(param: $0, value: value($0)) })
        } else {
            VStack(alignment: .leading, spacing: 9) {
                ForEach(params) { param in
                    ParamControl(param: param, value: value(param))
                }
            }
        }
    }
}
