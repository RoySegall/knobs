import AppKit
import KnobsKit
import SwiftUI

struct ContentView: View {
    @Bindable var library: LibraryModel
    let editor: EditorModel
    @Bindable var exporter: ExportModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                CanvasView(editor: editor)
                Divider()
                InspectorView(editor: editor)
            }
            Divider()
            FilmstripView(library: library, editor: editor, exporter: exporter)
        }
        .background(Color(white: 0.09))
        .navigationTitle(library.selection?.lastPathComponent ?? "Knobs")
        .navigationSubtitle(library.folder?.lastPathComponent ?? "")
        .task(id: library.selection) {
            guard let url = library.selection else {
                editor.close(saving: true)
                return
            }
            await editor.open(url: url)
            await PerfProbe.run(editor: editor)
            await PerfProbe.runExport(library: library, editor: editor, exporter: exporter)
            PerfProbe.runLibrary()
        }
        .onChange(of: editor.document) { _, document in
            if let url = editor.photo?.url {
                library.mark(url: url, edited: !document.isEmpty)
            }
        }
        .sheet(item: $exporter.presented) { request in
            ExportSheet(exporter: exporter, library: library, editor: editor, photo: request.photo, scope: request.scope)
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
            exportStatus
            Toggle(
                "Crop & Straighten",
                systemImage: "crop.rotate",
                isOn: Binding(get: { editor.isCropping }, set: { _ in editor.toggleCrop() })
            )
            .help("Crop & Straighten (R)")
            .disabled(editor.photo == nil)
            Toggle(
                "Graduated Filter",
                systemImage: "square.tophalf.filled",
                isOn: Binding(get: { editor.isEditingGradient }, set: { _ in editor.toggleGradient() })
            )
            .help("Graduated Filter (G)")
            .disabled(editor.photo == nil)
            Button(
                editor.compare == .original ? "Show Edited" : "Show Original",
                systemImage: editor.compare == .original ? "eye.slash" : "eye"
            ) { editor.toggleCompare() }
                .help("Before / after (\\)")
            Button("Reset All", systemImage: "arrow.counterclockwise") { editor.resetAll() }
                .disabled(editor.document.isEmpty)
            Button("Export", systemImage: "square.and.arrow.up") { exporter.present(scope: .single, photo: editor.photo?.url) }
                .help("Export (⌘E)")
                .disabled(editor.photo == nil)
        }
    }

    @ViewBuilder
    private var exportStatus: some View {
        switch exporter.phase {
        case .idle:
            EmptyView()
        case .exporting(let done, let total):
            HStack(spacing: 6) {
                ProgressView(value: Double(done), total: Double(max(total, 1)))
                    .frame(width: 70)
                Text("\(done)/\(total)")
                    .font(.system(size: 11).monospacedDigit())
                Button("Stop Export", systemImage: "xmark.circle.fill") { exporter.cancel() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
            }
        case .finished(let count, let failed, let folder):
            Button(failed.isEmpty ? "Exported \(count)" : "Exported \(count), \(failed.count) failed", systemImage: failed.isEmpty ? "checkmark.circle" : "exclamationmark.triangle") {
                NSWorkspace.shared.activateFileViewerSelecting([folder])
                exporter.dismiss()
            }
            .labelStyle(.titleAndIcon)
            .help(failed.isEmpty ? "Show in Finder" : "Failed: \(failed.joined(separator: ", "))")
        }
    }
}
