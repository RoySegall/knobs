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
    private(set) var compare = CompareMode.edited
    private(set) var tool = Tool.none

    /// Plugins left out of the preview.
    var skipping: Set<String> = [] {
        didSet { refresh() }
    }

    /// Per photo, kept while the app runs, so moving to the next photo and back keeps its undo steps.
    private var histories: [URL: EditHistory] = [:]
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

    /// The photo on screen or on its way there.
    var openURL: URL? {
        switch state {
        case .empty: nil
        case .loading(let url): url
        case .ready(let photo): photo.url
        case .failed(let url, _): url
        }
    }

    /// Leaves the photo. `saving: false` drops pending edits, for a photo headed to the Trash.
    func close(saving: Bool) {
        if saving {
            flushSave()
        } else {
            saveTask?.cancel()
            saveTask = nil
        }
        tool = .none
        state = .empty
        session = nil
        previewImage = nil
        document = EditDocument()
    }

    func value(param: KnobParam, plugin: any KnobPlugin) -> KnobValue {
        param.resolve(document.values(for: plugin.id)[param.id])
    }

    func isEdited(plugin: any KnobPlugin) -> Bool {
        !document.values(for: plugin.id).isEmpty
    }

    func set(value: KnobValue, param: KnobParam, plugin: any KnobPlugin) {
        edit(key: "\(plugin.id).\(param.id)") { $0.set(value: value, param: param, plugin: plugin.id) }
    }

    /// Several of one plugin's values with a single refresh, e.g. a crop rect's four edges.
    func set(values: [String: KnobValue], plugin: any KnobPlugin) {
        edit(key: "\(plugin.id).*") { document in
            for param in plugin.params {
                if let value = values[param.id] {
                    document.set(value: value, param: param, plugin: plugin.id)
                }
            }
        }
    }

    /// Puts a plugin's values back to exactly `values`, as one undo step.
    func replace(values: [String: KnobValue], plugin: any KnobPlugin) {
        edit(key: "replace.\(plugin.id)") { document in
            document.reset(plugin: plugin.id)
            for param in plugin.params {
                if let value = values[param.id] {
                    document.set(value: value, param: param, plugin: plugin.id)
                }
            }
        }
    }

    func reset(plugin: any KnobPlugin) {
        edit(key: "reset.\(plugin.id)") { $0.reset(plugin: plugin.id) }
    }

    func resetAll() {
        edit(key: "reset") { $0.resetAll() }
    }

    func restore(document: EditDocument) {
        self.document = document
        documentChanged()
    }

    // MARK: Undo

    var canUndo: Bool {
        photo.flatMap { histories[$0.url] }?.canUndo ?? false
    }

    var canRedo: Bool {
        photo.flatMap { histories[$0.url] }?.canRedo ?? false
    }

    func undo() {
        guard let url = photo?.url, let previous = histories[url]?.undo(current: document) else { return }
        document = previous
        documentChanged()
    }

    func redo() {
        guard let url = photo?.url, let next = histories[url]?.redo(current: document) else { return }
        document = next
        documentChanged()
    }

    /// Every edit goes through here so it lands in the photo's undo history.
    private func edit(key: String, _ change: (inout EditDocument) -> Void) {
        let before = document
        change(&document)
        guard document != before else { return }
        if let url = photo?.url {
            histories[url, default: EditHistory()].record(before: before, key: key, time: .now)
        }
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
        replace(values: saved, plugin: crop)
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
            replace(values: saved, plugin: plugin)
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
