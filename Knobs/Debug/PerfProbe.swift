import Foundation
import KnobsKit
import QuartzCore

/// Launch with `-knobsProbe <log path>` to measure the live preview: it drags exposure for two
/// seconds, logs frame timings and restores the edit. Does nothing otherwise.
enum PerfProbe {
    struct Frame {
        let cpu: Double
        let gpu: Double
        let latency: Double
    }

    /// What the probe drags: `exposure` (default) or `gradient`, given after the log path.
    static let mode: String = {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-knobsProbe"), arguments.indices.contains(index + 2) else { return "exposure" }
        return arguments[index + 2]
    }()

    static let logURL: URL? = {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-knobsProbe"), arguments.indices.contains(index + 1) else { return nil }
        return URL(fileURLWithPath: arguments[index + 1])
    }()

    /// Host time of the latest edit, so a frame can report how long it took to show it.
    static var lastChange: CFTimeInterval = 0
    static var sessionBuilds = 0
    static var canvas = ""
    private static var recording = false
    private static var frames: [Frame] = []
    private static var setTimes: [Double] = []
    /// From an edit until the main thread is free again: SwiftUI's update and the canvas draw included.
    private static var busyTimes: [Double] = []

    static func record(frame: Frame) {
        guard recording else { return }
        frames.append(frame)
    }

    /// Exports the folder's edited photos at 1080 px into `<log>.export/` and logs the outcome.
    static func runExport(library: LibraryModel, editor: EditorModel, exporter: ExportModel) async {
        guard let logURL, mode == "export" else { return }
        try? await Task.sleep(for: .seconds(1))
        let folder = logURL.appendingPathExtension("export")
        let saved = (exporter.folder, exporter.longEdge, exporter.format)
        exporter.folder = folder
        exporter.longEdge = 1080
        exporter.format = .jpeg
        let started = CACurrentMediaTime()
        exporter.start(scope: .edited, library: library, editor: editor)
        while true {
            try? await Task.sleep(for: .milliseconds(200))
            if case .finished = exporter.phase { break }
        }
        (exporter.folder, exporter.longEdge, exporter.format) = saved
        let report = "\(exporter.phase) in \(String(format: "%.1f", CACurrentMediaTime() - started)) s · edited \(library.edited.count)"
        try? report.write(to: logURL, atomically: true, encoding: .utf8)
        exporter.dismiss()
    }

    static func run(editor: EditorModel) async {
        guard let logURL, mode != "export", let plugin = editor.engine.plugin(id: "exposure"), let param = plugin.param("exposure") else { return }
        let original = editor.document
        if mode == "undo" {
            await checkUndo(editor: editor, plugin: plugin, param: param, logURL: logURL)
            return
        }
        if mode == "gradient", let gradient = editor.gradientPlugin {
            editor.set(values: ["exposure": .number(-1), "dehaze": .number(30), "clarity": .number(20)], plugin: gradient)
        }
        try? await Task.sleep(for: .seconds(1.5))
        recording = true
        let start = CACurrentMediaTime()
        var step = 0
        while CACurrentMediaTime() - start < 2 {
            let before = CACurrentMediaTime()
            lastChange = before
            if mode == "gradient" {
                let y = 0.3 + sin(Double(step) / 15) * 0.2
                editor.setGradient(GraduatedGradient(start: CGPoint(x: 0.5, y: 0), end: CGPoint(x: 0.5, y: y)))
            } else {
                editor.set(value: .number(sin(Double(step) / 15) * 1.5), param: param, plugin: plugin)
            }
            setTimes.append((CACurrentMediaTime() - before) * 1000)
            DispatchQueue.main.async { busyTimes.append((CACurrentMediaTime() - before) * 1000) }
            step += 1
            try? await Task.sleep(for: .milliseconds(8))
        }
        try? await Task.sleep(for: .milliseconds(200))
        recording = false
        let buildsBeforePause = sessionBuilds
        // A pause like a user's between drags: nothing should rebuild here.
        editor.restore(document: editor.document)
        try? await Task.sleep(for: .seconds(1))
        let pauseBuilds = sessionBuilds - buildsBeforePause
        editor.restore(document: original)

        func stats(_ values: [Double]) -> String {
            guard !values.isEmpty else { return "n/a" }
            let sorted = values.sorted()
            return String(format: "median %.2f · p90 %.2f · max %.2f ms", sorted[sorted.count / 2], sorted[sorted.count * 9 / 10], sorted.last!)
        }
        let report = """
        mode \(mode)
        photo \(editor.photo?.url.lastPathComponent ?? "-") · preview \(editor.previewImage.map { "\(Int($0.extent.width))x\(Int($0.extent.height))" } ?? "-")
        canvas \(canvas)
        session builds \(sessionBuilds) total, \(pauseBuilds) after an idle edit · scale \(editor.sessionScale) · preview/full \(editor.previewImage.map { $0.extent.width / (editor.photo?.fullSize.width ?? 1) } ?? 0)
        edits \(step) · frames drawn \(frames.count) (\(frames.count / 2) fps)
        set()     \(stats(setTimes))
        busy      \(stats(busyTimes))  (edit → main thread free)
        draw cpu  \(stats(frames.map(\.cpu)))
        draw gpu  \(stats(frames.map(\.gpu)))
        latency   \(stats(frames.map(\.latency)))  (edit → GPU done)
        """
        try? report.write(to: logURL, atomically: true, encoding: .utf8)
    }

    /// Drags exposure, then undoes and redoes, and logs what the document held at each point.
    private static func checkUndo(editor: EditorModel, plugin: any KnobPlugin, param: KnobParam, logURL: URL) async {
        let original = editor.document
        for step in 1...20 {
            editor.set(value: .number(Double(step) / 10), param: param, plugin: plugin)
            try? await Task.sleep(for: .milliseconds(16))
        }
        let dragged = editor.document.values(for: plugin.id)
        editor.undo()
        let undone = editor.document == original
        editor.redo()
        let redone = editor.document.values(for: plugin.id) == dragged
        editor.undo()
        let report = "drag \(dragged) · one undo restores original: \(undone) · redo brings drag back: \(redone) · canUndo after: \(editor.canUndo)"
        try? report.write(to: logURL, atomically: true, encoding: .utf8)
    }
}
