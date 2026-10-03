import AppKit
import KnobsKit
import Observation

/// The open folder and which photo in it is selected.
@Observable
final class LibraryModel {
    private(set) var folder: URL?
    private(set) var items: [URL] = []
    /// Photos with a sidecar, for the filmstrip badge and "export edited".
    private(set) var edited: Set<URL> = []
    var selection: URL?

    private static let lastFolderKey = "lastFolder"
    /// Folder path → file names taken out of Knobs (not off the disk), so they stay out next launch.
    private static let removedKey = "removedPhotos"
    private var removed: Set<String> = []

    init() {
        if let path = UserDefaults.standard.string(forKey: Self.lastFolderKey) {
            open(folder: URL(fileURLWithPath: path))
        }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Open"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(folder: url)
    }

    func open(folder: URL, select: URL? = nil) {
        removed = Set((UserDefaults.standard.dictionary(forKey: Self.removedKey)?[folder.path] as? [String]) ?? [])
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        items = contents
            .filter { Photo.fileExtensions.contains($0.pathExtension.lowercased()) && !removed.contains($0.lastPathComponent) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        edited = Set(items.filter { FileManager.default.fileExists(atPath: EditDocument.sidecarURL(for: $0).path) })
        self.folder = folder
        selection = select.flatMap { items.contains($0) ? $0 : nil } ?? items.first
        UserDefaults.standard.set(folder.path, forKey: Self.lastFolderKey)
    }

    var hasRemoved: Bool {
        !removed.isEmpty
    }

    /// Takes the photo out of Knobs only; the file and its edits stay on disk.
    func remove(url: URL) {
        removed.insert(url.lastPathComponent)
        saveRemoved()
        drop(url)
    }

    func restoreRemoved() {
        guard let folder else { return }
        removed = []
        saveRemoved()
        open(folder: folder, select: selection)
    }

    /// Moves the photo and its sidecar to the Trash, where the Finder can put them back.
    func moveToTrash(url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        let sidecar = EditDocument.sidecarURL(for: url)
        if FileManager.default.fileExists(atPath: sidecar.path) {
            try? FileManager.default.trashItem(at: sidecar, resultingItemURL: nil)
        }
        drop(url)
    }

    /// Selects the photo that took this one's place, as Lightroom does.
    private func drop(_ url: URL) {
        guard let index = items.firstIndex(of: url) else { return }
        items.remove(at: index)
        edited.remove(url)
        if selection == url {
            selection = items.isEmpty ? nil : items[min(index, items.count - 1)]
        }
    }

    private func saveRemoved() {
        guard let folder else { return }
        var all = UserDefaults.standard.dictionary(forKey: Self.removedKey) ?? [:]
        all[folder.path] = removed.isEmpty ? nil : removed.sorted()
        UserDefaults.standard.set(all, forKey: Self.removedKey)
    }

    func mark(url: URL, edited isEdited: Bool) {
        if isEdited {
            edited.insert(url)
        } else {
            edited.remove(url)
        }
    }

    func step(by offset: Int) {
        guard let selection, let index = items.firstIndex(of: selection) else {
            selection = items.first
            return
        }
        let next = index + offset
        guard items.indices.contains(next) else { return }
        self.selection = items[next]
    }
}
