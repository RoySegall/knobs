import KnobsKit
import SwiftUI

/// A button the app attaches to a panel's header by panel id, such as Auto on Light.
struct PanelAction {
    let title: String
    let help: String
    let perform: () -> Void
}

/// Draws every plugin's params, grouped by panel. Nothing here knows about any specific knob.
struct InspectorView: View {
    let editor: EditorModel
    var panelActions: [String: PanelAction] = [:]

    private var panels: [(panel: Panel, plugins: [any KnobPlugin])] {
        let visible = editor.engine.plugins.filter { $0.params.contains { $0.presentation == .inspector } }
        return Dictionary(grouping: visible) { $0.panel }
            .map { (panel: $0.key, plugins: $0.value.sorted { $0.panelOrder < $1.panelOrder }) }
            .sorted { $0.panel.order < $1.panel.order }
    }

    var body: some View {
        // The one read of the document here. Sections get value snapshots and compare them, so an edit
        // redraws only the section it touched instead of every control.
        let document = editor.document
        ScrollView {
            VStack(spacing: 0) {
                ForEach(panels, id: \.panel.id) { group in
                    PanelSection(
                        panel: group.panel,
                        plugins: group.plugins,
                        values: Dictionary(uniqueKeysWithValues: group.plugins.map { ($0.id, document.values(for: $0.id)) }),
                        action: panelActions[group.panel.id],
                        editor: editor
                    )
                    .equatable()
                    Divider()
                }
            }
        }
        .frame(width: 300)
        .background(Color(white: 0.13))
    }
}

struct PanelSection: View, Equatable {
    let panel: Panel
    let plugins: [any KnobPlugin]
    /// Each plugin's stored values, by plugin id.
    let values: [String: [String: KnobValue]]
    let action: PanelAction?
    let editor: EditorModel
    @AppStorage private var expanded: Bool

    init(panel: Panel, plugins: [any KnobPlugin], values: [String: [String: KnobValue]], action: PanelAction?, editor: EditorModel) {
        self.panel = panel
        self.plugins = plugins
        self.values = values
        self.action = action
        self.editor = editor
        _expanded = AppStorage(wrappedValue: true, "panel.\(panel.id).expanded")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button { expanded.toggle() } label: {
                    HStack {
                        Text(panel.title.uppercased())
                            .font(.system(size: 11, weight: .semibold))
                            .tracking(0.8)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if let action {
                    Button(action.title, action: action.perform)
                        .controlSize(.mini)
                        .help(action.help)
                }
                if values.values.contains(where: { !$0.isEmpty }) {
                    Button("Reset \(panel.title)", systemImage: "arrow.counterclockwise") {
                        plugins.forEach(editor.reset)
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                }
                Button { expanded.toggle() } label: {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if expanded {
                ForEach(plugins, id: \.id) { plugin in
                    PluginSection(
                        plugin: plugin,
                        values: values[plugin.id] ?? [:],
                        showsTitle: plugins.count > 1 && plugin.params.filter { $0.presentation == .inspector }.count > 1,
                        editor: editor
                    )
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

struct PluginSection: View {
    let plugin: any KnobPlugin
    /// A snapshot: reading the editor here would make every control redraw on any edit.
    let values: [String: KnobValue]
    let showsTitle: Bool
    let editor: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if showsTitle {
                Text(plugin.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .onTapGesture(count: 2) { editor.reset(plugin: plugin) }
                    .help("Double-click to reset")
            }
            ForEach(ParamRow.rows(for: plugin.params.filter { $0.presentation == .inspector })) { row in
                switch row {
                case .single(let param):
                    ParamControl(param: param, value: binding(param))
                case .group(_, let params):
                    ParamGroupControl(params: params, value: binding)
                }
            }
        }
    }

    private func binding(_ param: KnobParam) -> Binding<KnobValue> {
        Binding(
            get: { param.resolve(values[param.id]) },
            set: { editor.set(value: $0, param: param, plugin: plugin) }
        )
    }
}

extension PanelSection {
    nonisolated static func == (lhs: PanelSection, rhs: PanelSection) -> Bool {
        lhs.panel == rhs.panel && lhs.values == rhs.values && lhs.action?.title == rhs.action?.title
    }
}
