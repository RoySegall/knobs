import KnobsKit
import SwiftUI

/// Draws every plugin's params, grouped by panel. Nothing here knows about any specific knob.
struct InspectorView: View {
    let editor: EditorModel

    private var panels: [(panel: Panel, plugins: [any KnobPlugin])] {
        let visible = editor.engine.plugins.filter { $0.params.contains { $0.presentation == .inspector } }
        return Dictionary(grouping: visible) { $0.panel }
            .map { (panel: $0.key, plugins: $0.value.sorted { $0.order < $1.order }) }
            .sorted { $0.panel.order < $1.panel.order }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(panels, id: \.panel.id) { group in
                    PanelSection(panel: group.panel, plugins: group.plugins, editor: editor)
                    Divider()
                }
            }
        }
        .frame(width: 300)
        .background(Color(white: 0.13))
    }
}

struct PanelSection: View {
    let panel: Panel
    let plugins: [any KnobPlugin]
    let editor: EditorModel
    @AppStorage private var expanded: Bool

    init(panel: Panel, plugins: [any KnobPlugin], editor: EditorModel) {
        self.panel = panel
        self.plugins = plugins
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
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if plugins.contains(where: editor.isEdited) {
                    Button("Reset \(panel.title)", systemImage: "arrow.counterclockwise") {
                        plugins.forEach(editor.reset)
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                }
            }
            if expanded {
                ForEach(plugins, id: \.id) { plugin in
                    PluginSection(plugin: plugin, showsTitle: plugins.count > 1 && plugin.params.filter { $0.presentation == .inspector }.count > 1, editor: editor)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

struct PluginSection: View {
    let plugin: any KnobPlugin
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
            ForEach(plugin.params.filter { $0.presentation == .inspector }) { param in
                ParamControl(
                    param: param,
                    value: Binding(
                        get: { editor.value(param: param, plugin: plugin) },
                        set: { editor.set(value: $0, param: param, plugin: plugin) }
                    )
                )
            }
        }
    }
}
