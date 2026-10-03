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

    static let logURL: URL? = {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-knobsProbe"), arguments.indices.contains(index + 1) else { return nil }
        return URL(fileURLWithPath: arguments[index + 1])
    }()

    /// Host time of the latest edit, so a frame can report how long it took to show it.
    static var lastChange: CFTimeInterval = 0
    static var canvas = ""
    private static var recording = false
    private static var frames: [Frame] = []
    private static var setTimes: [Double] = []

    static func record(frame: Frame) {
        guard recording else { return }
        frames.append(frame)
    }

    static func run(editor: EditorModel) async {
        guard let logURL, let plugin = editor.engine.plugin(id: "exposure"), let param = plugin.param("exposure") else { return }
        let original = editor.document
        try? await Task.sleep(for: .seconds(1.5))
        recording = true
        let start = CACurrentMediaTime()
        var step = 0
        while CACurrentMediaTime() - start < 2 {
            let before = CACurrentMediaTime()
            lastChange = before
            editor.set(value: .number(sin(Double(step) / 15) * 1.5), param: param, plugin: plugin)
            setTimes.append((CACurrentMediaTime() - before) * 1000)
            step += 1
            try? await Task.sleep(for: .milliseconds(8))
        }
        try? await Task.sleep(for: .milliseconds(200))
        recording = false
        editor.restore(document: original)

        func stats(_ values: [Double]) -> String {
            guard !values.isEmpty else { return "n/a" }
            let sorted = values.sorted()
            return String(format: "median %.2f · p90 %.2f · max %.2f ms", sorted[sorted.count / 2], sorted[sorted.count * 9 / 10], sorted.last!)
        }
        let report = """
        photo \(editor.photo?.url.lastPathComponent ?? "-") · preview \(editor.previewImage.map { "\(Int($0.extent.width))x\(Int($0.extent.height))" } ?? "-")
        canvas \(canvas)
        edits \(step) · frames drawn \(frames.count) (\(frames.count / 2) fps)
        set()     \(stats(setTimes))
        draw cpu  \(stats(frames.map(\.cpu)))
        draw gpu  \(stats(frames.map(\.gpu)))
        latency   \(stats(frames.map(\.latency)))  (edit → GPU done)
        """
        try? report.write(to: logURL, atomically: true, encoding: .utf8)
    }
}
