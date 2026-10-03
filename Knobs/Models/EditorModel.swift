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

    /// What the canvas is for. Cropping previews the whole straightened photo under the crop overlay.
    /// Each tool keeps its plugin's values from before it opened, for Cancel.
    enum Tool {
        case none
        case crop(restoring: [String: KnobValue])
        case gradient(restoring: [String: KnobValue])
    }

    let engine: RenderEngine
    private(set) var state = LoadState.empty
    private(set) var document = EditDocument()
    /// The preview as a Core Image graph; `MetalCanvas` renders it on the next display refresh.
    private(set) var previewImage: CIImage?
    private(set) var exportPhase = ExportPhase.idle
    private(set) var compare = CompareMode.edited
    private(set) var tool = Tool.none

    /// Plugins left out of the preview.
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
        tool = .none
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
            matchResolution(now: true)
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

    /// Several of one plugin's values with a single refresh, e.g. a crop rect's four edges.
    func set(values: [String: KnobValue], plugin: any KnobPlugin) {
        for param in plugin.params {
            if let value = values[param.id] {
                document.set(value: value, param: param, plugin: plugin.id)
            }
        }
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
        matchResolution(now: true)
    }

    // MARK: Crop tool

    var cropPlugin: (any KnobPlugin)? {
        engine.plugin(id: "crop")
    }

    var isCropping: Bool {
        if case .crop = tool { true } else { false }
    }

    func toggleCrop() {
        if isCropping { commitCrop() } else { beginCrop() }
    }

    func beginCrop() {
        guard photo != nil, !isCropping, let crop = cropPlugin else { return }
        tool = .crop(restoring: document.values(for: crop.id))
        compare = .edited
        refresh()
        matchResolution(now: true)
    }

    func commitCrop() {
        guard isCropping else { return }
        tool = .none
        refresh()
        matchResolution(now: true)
    }

    func cancelCrop() {
        guard case .crop(let saved) = tool, let crop = cropPlugin else { return }
        tool = .none
        document.reset(plugin: crop.id)
        set(values: saved, plugin: crop)
        matchResolution(now: true)
    }

    var sessionScale: Double {
        session?.scale ?? 0
    }

    var hasOpenTool: Bool {
        if case .none = tool { false } else { true }
    }

    // MARK: Graduated filter tool

    var gradientPlugin: (any KnobPlugin)? {
        engine.plugin(id: "graduated_filter")
    }

    var isEditingGradient: Bool {
        if case .gradient = tool { true } else { false }
    }

    func toggleGradient() {
        if isEditingGradient { commitTool() } else { beginGradient() }
    }

    func beginGradient() {
        guard photo != nil, !isEditingGradient, let plugin = gradientPlugin else { return }
        if isCropping { commitCrop() }
        tool = .gradient(restoring: document.values(for: plugin.id))
        if compare == .original { toggleCompare() }
    }

    /// Return and Done: keep what the open tool did.
    func commitTool() {
        switch tool {
        case .none: break
        case .crop: commitCrop()
        case .gradient: tool = .none
        }
    }

    /// Escape and Cancel: put the open tool's plugin back as it was.
    func cancelTool() {
        switch tool {
        case .none:
            break
        case .crop:
            cancelCrop()
        case .gradient(let saved):
            guard let plugin = gradientPlugin else { return }
            tool = .none
            document.reset(plugin: plugin.id)
            set(values: saved, plugin: plugin)
        }
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
        rebuildSession(after: .milliseconds(250))
    }

    /// Builds off the main thread, after `delay` when given, so a resize or crop settles first.
    private func rebuildSession(after delay: Duration?) {
        resizeTask?.cancel()
        resizeTask = Task {
            if let delay {
                try? await Task.sleep(for: delay)
            }
            guard !Task.isCancelled, let photo else { return }
            let session = await makeSession(photo: photo)
            guard !Task.isCancelled, self.photo?.url == photo.url else { return }
            self.session = session
            refresh()
        }
    }

    /// Built off the main thread: the first decode and downscale of a big photo takes a while.
    private func makeSession(photo: Photo) async -> PreviewSession {
        PerfProbe.sessionBuilds += 1
        let engine = engine
        let size = maxPixelSize(for: photo)
        return await Task.detached(priority: .userInitiated) {
            engine.previewSession(photo: photo, maxPixelSize: size)
        }.value
    }

    /// Sized so the edited output, crop included, fills the viewport rather than being upscaled by the canvas.
    private func maxPixelSize(for photo: Photo) -> Int {
        let output = outputSize ?? photo.fullSize
        let fit = min(viewport.width / output.width, viewport.height / output.height)
        return Int((max(photo.fullSize.width, photo.fullSize.height) * fit).rounded())
    }

    /// The edited output in full-resolution pixels, measured off the current preview.
    private var outputSize: CGSize? {
        guard compare == .edited, let session, let extent = previewImage?.extent, extent.width >= 1, extent.height >= 1 else { return nil }
        return CGSize(width: extent.width / session.scale, height: extent.height / session.scale)
    }

    /// A crop changes the output's size; rebuild when the canvas would upscale the preview by more than 3%,
    /// or downscale it by more than 15% every frame. `now` skips the debounce for one-off actions.
    private func matchResolution(now: Bool) {
        guard let photo, let session, outputSize != nil else { return }
        let wanted = min(1, Double(maxPixelSize(for: photo)) / max(photo.fullSize.width, photo.fullSize.height))
        let ratio = wanted / session.scale
        guard ratio > 1.03 || ratio < 0.85 else { return }
        rebuildSession(after: now ? nil : .milliseconds(250))
    }

    private func refresh() {
        previewImage = session?.image(
            document: compare == .original ? EditDocument() : document,
            skipping: skipping,
            framing: isCropping ? .uncropped : .cropped
        )
    }

    private func documentChanged() {
        refresh()
        scheduleSave()
        matchResolution(now: false)
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
