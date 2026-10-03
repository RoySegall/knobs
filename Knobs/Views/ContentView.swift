import AppKit
import KnobsKit
import SwiftUI

struct ContentView: View {
    @Bindable var library: LibraryModel
    let editor: EditorModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                CanvasView(editor: editor)
                Divider()
                InspectorView(editor: editor)
            }
            Divider()
            FilmstripView(library: library)
        }
        .background(Color(white: 0.09))
        .navigationTitle(library.selection?.lastPathComponent ?? "Knobs")
        .navigationSubtitle(library.folder?.lastPathComponent ?? "")
        .task(id: library.selection) {
            if let url = library.selection {
                await editor.open(url: url)
                await PerfProbe.run(editor: editor)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            editor.flushSave()
        }
        .toolbar { toolbar }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button("Open Folder", systemImage: "folder") { library.chooseFolder() }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if case .exporting = editor.exportPhase {
                ProgressView().controlSize(.small)
            }
            Toggle(
                "Crop & Straighten",
                systemImage: "crop.rotate",
                isOn: Binding(get: { editor.isCropping }, set: { _ in editor.toggleCrop() })
            )
            .help("Crop & Straighten (R)")
            .disabled(editor.photo == nil)
            Button(
                editor.compare == .original ? "Show Edited" : "Show Original",
                systemImage: editor.compare == .original ? "eye.slash" : "eye"
            ) { editor.toggleCompare() }
                .help("Before / after (\\)")
            Button("Reset All", systemImage: "arrow.counterclockwise") { editor.resetAll() }
                .disabled(editor.document.isEmpty)
            Menu("Export", systemImage: "square.and.arrow.up") {
                ForEach(ExportFormat.allCases, id: \.self) { format in
                    Button(format.title) { Exporter.run(editor: editor, format: format) }
                }
            }
            .disabled(editor.photo == nil)
        }
    }
}
