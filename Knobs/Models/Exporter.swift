import AppKit
import KnobsKit
import UniformTypeIdentifiers

enum Exporter {
    static func run(editor: EditorModel, format: ExportFormat) {
        guard let photo = editor.photo else { return }
        let panel = NSSavePanel()
        panel.directoryURL = photo.url.deletingLastPathComponent()
        panel.nameFieldStringValue = photo.url.deletingPathExtension().lastPathComponent + "-knobs." + format.fileExtension
        panel.allowedContentTypes = [UTType(filenameExtension: format.fileExtension)].compactMap { $0 }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await editor.export(format: format, to: url) }
    }
}

extension ExportFormat {
    var title: String {
        switch self {
        case .jpeg: "JPEG"
        case .heic: "HEIC"
        case .tiff: "TIFF (16-bit)"
        }
    }
}
