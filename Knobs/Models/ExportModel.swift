import AppKit
import KnobsKit
import Observation

/// Export settings and the export in progress. Settings persist between launches.
@Observable
final class ExportModel {
    enum Scope: Hashable {
        /// One photo, given with the request.
        case single
        /// Every photo in the folder that has edits.
        case edited
    }

    struct Request: Identifiable {
        let id = UUID()
        let photo: URL?
        let scope: Scope
    }

    enum Phase {
        case idle
        case exporting(done: Int, total: Int)
        case finished(count: Int, failed: [String], folder: URL)
    }

    /// Long edges offered in the sheet; 0 is full resolution.
    static let sizes = [0, 4096, 3840, 2048, 1080]

    var presented: Request?
    var format: ExportFormat {
        didSet { defaults.set(format.rawValue, forKey: Key.format) }
    }
    var quality: Double {
        didSet { defaults.set(quality, forKey: Key.quality) }
    }
    var longEdge: Int {
        didSet { defaults.set(longEdge, forKey: Key.longEdge) }
    }
    /// Nil exports into a "Knobs Export" folder next to the photos.
    var folder: URL? {
        didSet { defaults.set(folder?.path, forKey: Key.folder) }
    }
    private(set) var phase = Phase.idle

    private let defaults = UserDefaults.standard
    private var task: Task<Void, Never>?

    private enum Key {
        static let format = "export.format"
        static let quality = "export.quality"
        static let longEdge = "export.longEdge"
        static let folder = "export.folder"
    }

    init() {
        format = defaults.string(forKey: Key.format).flatMap(ExportFormat.init(rawValue:)) ?? .jpeg
        quality = defaults.object(forKey: Key.quality) as? Double ?? 0.92
        longEdge = defaults.integer(forKey: Key.longEdge)
        folder = defaults.string(forKey: Key.folder).map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    func present(scope: Scope, photo: URL?) {
        presented = Request(photo: photo, scope: scope)
    }

    func photos(scope: Scope, photo: URL?, library: LibraryModel) -> [URL] {
        switch scope {
        case .single: photo.map { [$0] } ?? []
        case .edited: library.items.filter(library.edited.contains)
        }
    }

    func destination(for photos: [URL]) -> URL? {
        folder ?? photos.first?.deletingLastPathComponent().appendingPathComponent("Knobs Export", isDirectory: true)
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        folder = url
    }

    func start(scope: Scope, photo: URL?, library: LibraryModel, editor: EditorModel) {
        editor.flushSave()
        let photos = photos(scope: scope, photo: photo, library: library)
        guard let destination = destination(for: photos), !photos.isEmpty else { return }
        presented = nil
        let engine = editor.engine
        let options = ExportOptions(format: format, quality: quality, maxPixelSize: longEdge == 0 ? nil : longEdge)
        let names = Self.fileNames(for: photos, format: format)
        task?.cancel()
        task = Task {
            var exported = 0
            var failed: [String] = []
            do {
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            } catch {
                phase = .finished(count: 0, failed: [error.localizedDescription], folder: destination)
                return
            }
            for (index, url) in photos.enumerated() {
                guard !Task.isCancelled else { break }
                phase = .exporting(done: index, total: photos.count)
                let target = destination.appendingPathComponent(names[index])
                do {
                    // Off the main thread: a full-resolution RAW takes a second or two.
                    try await Task.detached(priority: .utility) {
                        try engine.export(photo: Photo.load(url: url), document: EditDocument.load(for: url), options: options, to: target)
                    }.value
                    exported += 1
                } catch {
                    failed.append(url.lastPathComponent)
                }
            }
            phase = .finished(count: exported, failed: failed, folder: destination)
        }
    }

    func cancel() {
        task?.cancel()
    }

    func dismiss() {
        phase = .idle
    }

    /// "IMG_1.jpg", or "IMG_1-cr3.jpg" when a JPEG and a RAW of the same shot both export.
    static func fileNames(for photos: [URL], format: ExportFormat) -> [String] {
        let bases = photos.map { $0.deletingPathExtension().lastPathComponent }
        let counts = Dictionary(bases.map { ($0.lowercased(), 1) }, uniquingKeysWith: +)
        return zip(photos, bases).map { url, base in
            let unique = counts[base.lowercased()] == 1 ? base : "\(base)-\(url.pathExtension.lowercased())"
            return "\(unique).\(format.fileExtension)"
        }
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
