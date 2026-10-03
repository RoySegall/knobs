import CoreImage
import Foundation
import KnobsKit
import Observation

/// The photo being edited, its edit document and the live preview.
@Observable
final class EditorModel {
    enum LoadState {
        case empty
        case loading(URL)
        case ready(Photo)
        case failed(URL, message: String)
    }

    enum CompareMode {
        case edited
        case original
    }

    enum ExportPhase {
        case idle
        case exporting
        case done(URL)
        case failed(String)
    }

    let engine: RenderEngine
    private(set) var state = LoadState.empty
    private(set) var document = EditDocument()
    /// The preview as a Core Image graph; `MetalCanvas` renders it on the next display refresh.
    private(set) var previewImage: CIImage?
    private(set) var exportPhase = ExportPhase.idle
    private(set) var compare = CompareMode.edited

    /// Plugins left out of the preview, e.g. the crop while its tool is open.
    var skipping: Set<String> = [] {
        didSet { refresh() }
    }

    private var session: PreviewSession?
    private var viewport = CGSize(width: 2048, height: 2048)
    private var resizeTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?

    init(engine: RenderEngine) {
        self.engine = engine
    }

    var photo: Photo? {
        if case .ready(let photo) = state { photo } else { nil }
    }

    func open(url: URL) async {
        flushSave()
        state = .loading(url)
        session = nil
        previewImage = nil
        do {
            let photo = try await Task.detached(priority: .userInitiated) { try Photo.load(url: url) }.value
            guard case .loading(let current) = state, current == url else { return }
            document = Self.loadDocument(for: url)
            let session = await makeSession(photo: photo)
            guard case .loading(let current) = state, current == url else { return }
            compare = .edited
            state = .ready(photo)
            self.session = session
            refresh()
        } catch {
            state = .failed(url, message: error.localizedDescription)
        }
    }

    func value(param: KnobParam, plugin: any KnobPlugin) -> KnobValue {
        param.resolve(document.values(for: plugin.id)[param.id])
    }

    func isEdited(plugin: any KnobPlugin) -> Bool {
        !document.values(for: plugin.id).isEmpty
    }

    func set(value: KnobValue, param: KnobParam, plugin: any KnobPlugin) {
        document.set(value: value, param: param, plugin: plugin.id)
        documentChanged()
    }

    func reset(plugin: any KnobPlugin) {
        document.reset(plugin: plugin.id)
        documentChanged()
    }

    func resetAll() {
        document.resetAll()
        documentChanged()
    }

    func restore(document: EditDocument) {
        self.document = document
        documentChanged()
    }

    func toggleCompare() {
        compare = compare == .edited ? .original : .edited
        refresh()
    }

    func export(format: ExportFormat, to url: URL) async {
        guard let photo else { return }
        exportPhase = .exporting
        let engine = engine
        let document = document
        do {
            try await Task.detached(priority: .userInitiated) {
                try engine.export(photo: photo, document: document, format: format, to: url)
            }.value
            exportPhase = .done(url)
        } catch {
            exportPhase = .failed(error.localizedDescription)
        }
    }

    func flushSave() {
        guard let saveTask else { return }
        saveTask.cancel()
        self.saveTask = nil
        if let url = photo?.url {
            try? document.save(for: url)
        }
    }

    /// Rebuilds the session at the new size once a resize settles; the canvas scales the old one meanwhile.
    func updateViewport(pixels: CGSize) {
        guard pixels != viewport else { return }
        viewport = pixels
        resizeTask?.cancel()
        resizeTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let photo else { return }
            let session = await makeSession(photo: photo)
            guard !Task.isCancelled, self.photo?.url == photo.url else { return }
            self.session = session
            refresh()
        }
    }

    /// Built off the main thread: the first decode and downscale of a big photo takes a while.
    private func makeSession(photo: Photo) async -> PreviewSession {
        let engine = engine
        let size = maxPixelSize(for: photo)
        return await Task.detached(priority: .userInitiated) {
            engine.previewSession(photo: photo, maxPixelSize: size)
        }.value
    }

    private func maxPixelSize(for photo: Photo) -> Int {
        let fit = min(viewport.width / photo.fullSize.width, viewport.height / photo.fullSize.height)
        return Int((max(photo.fullSize.width, photo.fullSize.height) * fit).rounded())
    }

    private func refresh() {
        previewImage = session?.image(document: compare == .original ? EditDocument() : document, skipping: skipping)
    }

    private func documentChanged() {
        refresh()
        scheduleSave()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        guard let url = photo?.url else { return }
        let document = document
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            try? document.save(for: url)
            saveTask = nil
        }
    }

    /// A corrupt sidecar is moved aside rather than overwritten by the next edit.
    private static func loadDocument(for url: URL) -> EditDocument {
        do {
            return try EditDocument.load(for: url)
        } catch {
            let sidecar = EditDocument.sidecarURL(for: url)
            try? FileManager.default.moveItem(at: sidecar, to: sidecar.appendingPathExtension("corrupt"))
            return EditDocument()
        }
    }
}
