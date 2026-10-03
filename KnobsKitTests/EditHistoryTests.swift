import Foundation
import Testing
@testable import KnobsKit

@Suite("EditHistory")
struct EditHistoryTests {
    static let param = KnobParam.slider(id: "amount", title: "Amount", range: -100...100)
    static let start = Date(timeIntervalSinceReferenceDate: 0)

    static func document(_ amount: Double) -> EditDocument {
        var document = EditDocument()
        document.set(value: .number(amount), param: param, plugin: "contrast")
        return document
    }

    @Suite("undo")
    struct Undo {
        @Test("should have nothing to undo or redo when new")
        func empty() {
            var history = EditHistory()
            #expect(history.undo(current: EditDocument()) == nil)
            #expect(history.redo(current: EditDocument()) == nil)
        }

        @Test("should undo a whole drag on one knob in one step")
        func coalesces() {
            var history = EditHistory()
            for step in 0..<10 {
                let time = EditHistoryTests.start.addingTimeInterval(Double(step) * 0.05)
                history.record(before: EditHistoryTests.document(Double(step)), key: "contrast.amount", time: time)
            }
            #expect(history.undo(current: EditHistoryTests.document(10)) == EditHistoryTests.document(0))
            #expect(!history.canUndo)
        }

        @Test("should start a new step after a pause or on another knob")
        func separates() {
            var history = EditHistory()
            history.record(before: EditHistoryTests.document(0), key: "contrast.amount", time: EditHistoryTests.start)
            history.record(before: EditHistoryTests.document(1), key: "exposure.exposure", time: EditHistoryTests.start.addingTimeInterval(0.1))
            history.record(before: EditHistoryTests.document(2), key: "exposure.exposure", time: EditHistoryTests.start.addingTimeInterval(2))
            #expect(history.undo(current: EditHistoryTests.document(3)) == EditHistoryTests.document(2))
            #expect(history.undo(current: EditHistoryTests.document(2)) == EditHistoryTests.document(1))
            #expect(history.undo(current: EditHistoryTests.document(1)) == EditHistoryTests.document(0))
        }
    }

    @Suite("redo")
    struct Redo {
        @Test("should drop redo steps once a new change is made")
        func clearedByChange() {
            var history = EditHistory()
            history.record(before: EditHistoryTests.document(0), key: "contrast.amount", time: EditHistoryTests.start)
            _ = history.undo(current: EditHistoryTests.document(1))
            history.record(before: EditHistoryTests.document(0), key: "contrast.amount", time: EditHistoryTests.start.addingTimeInterval(5))
            #expect(!history.canRedo)
        }

        @Test("should bring back what was undone")
        func roundTrip() {
            var history = EditHistory()
            history.record(before: EditHistoryTests.document(0), key: "contrast.amount", time: EditHistoryTests.start)
            let undone = history.undo(current: EditHistoryTests.document(1))
            #expect(undone == EditHistoryTests.document(0))
            #expect(history.redo(current: EditHistoryTests.document(0)) == EditHistoryTests.document(1))
        }
    }
}
