import Foundation

/// Undo and redo for one photo's edits. Changes to the same knob within `gap` of each other form one
/// step, so a whole slider drag undoes at once.
public struct EditHistory: Sendable {
    public static let gap: TimeInterval = 0.6
    /// Enough for a long session; the oldest steps go first.
    static let limit = 200

    private var undoStack: [EditDocument] = []
    private var redoStack: [EditDocument] = []
    private var last: (key: String, time: Date)?

    public init() {}

    public var canUndo: Bool {
        !undoStack.isEmpty
    }

    public var canRedo: Bool {
        !redoStack.isEmpty
    }

    /// Call after a change, with the document as it was before it. `key` names what changed.
    public mutating func record(before: EditDocument, key: String, time: Date) {
        let continues = last.map { $0.key == key && time.timeIntervalSince($0.time) < Self.gap } ?? false
        if !continues {
            undoStack.append(before)
            if undoStack.count > Self.limit {
                undoStack.removeFirst()
            }
        }
        redoStack.removeAll()
        last = (key, time)
    }

    /// The document to show after undoing, or nil when there is nothing to undo.
    public mutating func undo(current: EditDocument) -> EditDocument? {
        guard let previous = undoStack.popLast() else { return nil }
        redoStack.append(current)
        last = nil
        return previous
    }

    public mutating func redo(current: EditDocument) -> EditDocument? {
        guard let next = redoStack.popLast() else { return nil }
        undoStack.append(current)
        last = nil
        return next
    }
}
