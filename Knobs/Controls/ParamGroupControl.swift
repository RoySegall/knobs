import KnobsKit
import SwiftUI

/// One inspector row: a lone param, or every param sharing a `group`, placed where the first of them sits.
/// Consecutive ungrouped wheels form a group of their own, so grading reads as a block of wheels.
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
                if case .wheel = param.kind, case .group(let id, let members) = rows.last, id.hasPrefix("wheels."),
                   case .wheel = members[0].kind {
                    rows[rows.count - 1] = .group(id: id, params: members + [param])
                } else if case .wheel = param.kind {
                    rows.append(.group(id: "wheels.\(param.id)", params: [param]))
                } else {
                    rows.append(.single(param))
                }
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

/// Draws a param group as one control. Curves share one editor with a picker, wheels sit in a two-column
/// grid, other kinds simply stack.
struct ParamGroupControl: View {
    let params: [KnobParam]
    let value: (KnobParam) -> Binding<KnobValue>

    var body: some View {
        if params.allSatisfy({ if case .curve = $0.kind { true } else { false } }) {
            CurveEditor(channels: params.map { CurveEditor.Channel(param: $0, value: value($0)) })
        } else if params.allSatisfy({ if case .wheel = $0.kind { true } else { false } }) {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 10) {
                ForEach(params) { param in
                    ParamControl(param: param, value: value(param))
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 9) {
                ForEach(params) { param in
                    ParamControl(param: param, value: value(param))
                }
            }
        }
    }
}
