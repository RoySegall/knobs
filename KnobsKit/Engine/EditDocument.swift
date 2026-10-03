import Foundation

/// A photo's edits, stored next to it as `<file>.knobs`. Only values that differ from the default are kept.
public struct EditDocument: Sendable, Hashable, Codable {
    public var version: Int
    public var plugins: [String: [String: KnobValue]]

    public init() {
        version = 1
        plugins = [:]
    }

    public var isEmpty: Bool {
        plugins.isEmpty
    }

    public func values(for pluginID: String) -> [String: KnobValue] {
        plugins[pluginID] ?? [:]
    }

    public mutating func set(value: KnobValue, param: KnobParam, plugin pluginID: String) {
        var values = plugins[pluginID] ?? [:]
        values[param.id] = value == param.defaultValue ? nil : value
        plugins[pluginID] = values.isEmpty ? nil : values
    }

    public mutating func reset(plugin pluginID: String) {
        plugins[pluginID] = nil
    }

    public mutating func resetAll() {
        plugins = [:]
    }
}

extension EditDocument {
    public static func sidecarURL(for photo: URL) -> URL {
        photo.appendingPathExtension("knobs")
    }

    /// An empty document when there is no sidecar yet. Throws on a corrupt one so it is never overwritten blind.
    public static func load(for photo: URL) throws -> EditDocument {
        let url = sidecarURL(for: photo)
        guard FileManager.default.fileExists(atPath: url.path) else { return EditDocument() }
        return try JSONDecoder().decode(EditDocument.self, from: Data(contentsOf: url))
    }

    /// Deletes the sidecar when there is nothing left to keep.
    public func save(for photo: URL) throws {
        let url = Self.sidecarURL(for: photo)
        guard !isEmpty else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
