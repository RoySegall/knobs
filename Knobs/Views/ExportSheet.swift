import KnobsKit
import SwiftUI

struct ExportSheet: View {
    @Bindable var exporter: ExportModel
    let library: LibraryModel
    let editor: EditorModel
    @State var scope: ExportModel.Scope

    var body: some View {
        let photos = exporter.photos(scope: scope, library: library, editor: editor)
        let edited = exporter.photos(scope: .edited, library: library, editor: editor).count
        VStack(alignment: .leading, spacing: 14) {
            Text("Export").font(.headline)
            Form {
                Picker("Photos", selection: $scope) {
                    Text("This photo").tag(ExportModel.Scope.current)
                    Text("Edited photos (\(edited))").tag(ExportModel.Scope.edited)
                }
                .pickerStyle(.segmented)
                Picker("Format", selection: $exporter.format) {
                    ForEach(ExportFormat.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                if exporter.format != .tiff {
                    LabeledContent("Quality") {
                        HStack {
                            Slider(value: $exporter.quality, in: 0.5...1)
                            Text("\(Int((exporter.quality * 100).rounded()))")
                                .monospacedDigit()
                                .frame(width: 28, alignment: .trailing)
                        }
                    }
                }
                Picker("Size", selection: $exporter.longEdge) {
                    ForEach(ExportModel.sizes, id: \.self) { size in
                        Text(size == 0 ? "Full resolution" : "Long edge \(size) px").tag(size)
                    }
                }
                LabeledContent("Folder") {
                    HStack {
                        Text(exporter.folder?.path ?? "“Knobs Export” next to the photos")
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if exporter.folder != nil {
                            Button("Reset") { exporter.folder = nil }
                        }
                        Button("Choose…") { exporter.chooseFolder() }
                    }
                }
            }
            .formStyle(.grouped)
            Text("A file with the same name in that folder is replaced.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { exporter.presented = nil }
                    .keyboardShortcut(.cancelAction)
                Button(photos.count == 1 ? "Export" : "Export \(photos.count) Photos") {
                    exporter.start(scope: scope, library: library, editor: editor)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(photos.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
