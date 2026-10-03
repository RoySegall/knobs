import CoreGraphics
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

    private enum RenderPhase {
        case idle
        case rendering
        /// A render is running and the inputs changed since it started.
        case stale
    }

    let engine: RenderEngine
    private(set) var state = LoadState.empty
    private(set) var document = EditDocument()
    private(set) var preview: CGImage?
    private(set) var exportPhase = ExportPhase.idle
    private(set) var compare = CompareMode.edited

    /// Plugins left out of the preview, e.g. the crop while its tool is open.
    var skipping: Set<String> = [] {
        didSet { requestRender() }
    }

    private var renderPhase = RenderPhase.idle
    private var saveTask: Task<Void, Never>?
    private let previewSize = 2048

    init(engine: RenderEngine) {
        self.engine = engine
    }

    var photo: Photo? {
        if case .ready(let photo) = state { photo } else { nil }
    }

    func open(url: URL) async {
        flushSave()
        state = .loading(url)
        preview = nil
        do {
            let photo = try await Task.detached(priority: .userInitiated) { try Photo.load(url: url) }.value
            guard case .loading(let current) = state, current == url else { return }
            document = Self.loadDocument(for: url)
            compare = .edited
            state = .ready(photo)
            requestRender()
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

    func toggleCompare() {
        compare = compare == .edited ? .original : .edited
        requestRender()
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

    private func documentChanged() {
        requestRender()
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

    // Latest wins: at most one render runs, and one more follows if inputs changed meanwhile.
    private func requestRender() {
        switch renderPhase {
        case .idle: startRender()
        case .rendering: renderPhase = .stale
        case .stale: break
        }
    }

    private func startRender() {
        guard let photo else {
            renderPhase = .idle
            return
        }
        renderPhase = .rendering
        let engine = engine
        let document = compare == .original ? EditDocument() : document
        let request = RenderRequest(maxPixelSize: previewSize, skipping: skipping)
        Task {
            let image = await Task.detached(priority: .userInitiated) {
                engine.cgImage(photo: photo, document: document, request: request)
            }.value
            if self.photo?.url == photo.url {
                preview = image
            }
            if renderPhase == .stale {
                startRender()
            } else {
                renderPhase = .idle
            }
        }
    }
}
