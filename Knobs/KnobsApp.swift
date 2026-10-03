import KnobsKit
import SwiftUI

@main
struct KnobsApp: App {
    @State private var library = LibraryModel()
    @State private var editor = EditorModel(engine: RenderEngine())

    var body: some Scene {
        Window("Knobs", id: "main") {
            ContentView(library: library, editor: editor)
                .frame(minWidth: 1000, minHeight: 680)
                .preferredColorScheme(.dark)
        }
        .commands { KnobsCommands(library: library, editor: editor) }
    }
}

struct KnobsCommands: Commands {
    let library: LibraryModel
    let editor: EditorModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open Folder…") { library.chooseFolder() }
                .keyboardShortcut("o")
        }
        CommandMenu("Photo") {
            Button("Previous Photo") { library.step(by: -1) }
                .keyboardShortcut(.leftArrow, modifiers: [])
            Button("Next Photo") { library.step(by: 1) }
                .keyboardShortcut(.rightArrow, modifiers: [])
            Divider()
            Button(editor.compare == .original ? "Show Edited" : "Show Original") { editor.toggleCompare() }
                .keyboardShortcut("\\", modifiers: [])
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
            Divider()
            ForEach(ExportFormat.allCases, id: \.self) { format in
                Button("Export \(format.title)…") { Exporter.run(editor: editor, format: format) }
            }
        }
    }
}
