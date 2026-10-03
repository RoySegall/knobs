import KnobsKit
import SwiftUI

@main
struct KnobsApp: App {
    @State private var library = LibraryModel()
    @State private var editor = EditorModel(engine: RenderEngine())
    @State private var exporter = ExportModel()

    var body: some Scene {
        Window("Knobs", id: "main") {
            ContentView(library: library, editor: editor, exporter: exporter)
                .frame(minWidth: 1000, minHeight: 680)
                .preferredColorScheme(.dark)
        }
        .commands { KnobsCommands(library: library, editor: editor, exporter: exporter) }
    }
}

struct KnobsCommands: Commands {
    let library: LibraryModel
    let editor: EditorModel
    let exporter: ExportModel

    var body: some Commands {
        CommandGroup(replacing: .undoRedo) {
            Button("Undo") { editor.undo() }
                .keyboardShortcut("z")
                .disabled(!editor.canUndo)
            Button("Redo") { editor.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!editor.canRedo)
        }
        CommandGroup(replacing: .newItem) {
            Button("Open Folder…") { library.chooseFolder() }
                .keyboardShortcut("o")
            Divider()
            Button("Export…") { exporter.present(scope: .single, photo: editor.photo?.url) }
                .keyboardShortcut("e")
                .disabled(editor.photo == nil)
            Button("Export Edited Photos…") { exporter.present(scope: .edited, photo: editor.photo?.url) }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(library.edited.isEmpty)
            Divider()
            Button("Restore Removed Photos") { library.restoreRemoved() }
                .disabled(!library.hasRemoved)
        }
        CommandMenu("Photo") {
            Button("Previous Photo") { library.step(by: -1) }
                .keyboardShortcut(.leftArrow, modifiers: [])
            Button("Next Photo") { library.step(by: 1) }
                .keyboardShortcut(.rightArrow, modifiers: [])
            Divider()
            Button(editor.compare == .original ? "Show Edited" : "Show Original") { editor.toggleCompare() }
                .keyboardShortcut("\\", modifiers: [])
            Button("Auto Tone") { editor.autoTone() }
                .keyboardShortcut("u")
                .disabled(editor.photo == nil)
            Button("Reset All Edits") { editor.resetAll() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Divider()
            Button(editor.isCropping ? "Done Cropping" : "Crop & Straighten") { editor.toggleCrop() }
                .keyboardShortcut("r", modifiers: [])
                .disabled(editor.photo == nil)
            Button(editor.isEditingGradient ? "Done with Graduated Filter" : "Graduated Filter") { editor.toggleGradient() }
                .keyboardShortcut("g", modifiers: [])
                .disabled(editor.photo == nil)
            Button("Apply") { editor.commitTool() }
                .keyboardShortcut(.return, modifiers: [])
                .disabled(!editor.hasOpenTool)
            Button("Cancel") { editor.cancelTool() }
                .keyboardShortcut(.escape, modifiers: [])
                .disabled(!editor.hasOpenTool)
            Button("Swap Crop Orientation") { editor.swapCropOrientation() }
                .keyboardShortcut("x", modifiers: [])
                .disabled(!editor.isCropping)
        }
    }
}
