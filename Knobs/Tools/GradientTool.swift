import KnobsKit

/// The graduated filter's position, read from and written to the document.
extension EditorModel {
    var gradient: GraduatedGradient? {
        guard let plugin = gradientPlugin else { return nil }
        return GraduatedGradient(values: KnobValues(params: plugin.params, stored: document.values(for: plugin.id)))
    }

    func setGradient(_ gradient: GraduatedGradient) {
        guard let plugin = gradientPlugin else { return }
        set(values: gradient.values, plugin: plugin)
    }
}
