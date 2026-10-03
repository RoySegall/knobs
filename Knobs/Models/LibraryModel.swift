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

    func open(folder: URL) {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        items = contents
            .filter { Photo.fileExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        edited = Set(items.filter { FileManager.default.fileExists(atPath: EditDocument.sidecarURL(for: $0).path) })
        self.folder = folder
        selection = items.first
        UserDefaults.standard.set(folder.path, forKey: Self.lastFolderKey)
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
