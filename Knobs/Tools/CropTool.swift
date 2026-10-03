import CoreGraphics
import KnobsKit

/// The crop edits the canvas tool makes. The math lives in `CropGeometry`; this reads and writes the document.
extension EditorModel {
    /// The crop's stored values, typed.
    var cropSettings: CropSettings? {
        guard let crop = cropPlugin else { return nil }
        return CropSettings(values: KnobValues(params: crop.params, stored: document.values(for: crop.id)))
    }

    func setCrop(rect: CGRect) {
        guard let crop = cropPlugin else { return }
        set(values: CropSettings.values(rect: rect), plugin: crop)
    }

    /// Rounded to the inspector's two decimals so the slider and the sidecar agree.
    func setCrop(angle: Double) {
        guard let crop = cropPlugin, let param = crop.param(CropSettings.Key.angle) else { return }
        set(value: .number((angle * 100).rounded() / 100), param: param, plugin: crop)
    }

    /// Lightroom's X: turns the crop between landscape and portrait.
    func swapCropOrientation() {
        guard isCropping, let photo, let settings = cropSettings else { return }
        let geometry = settings.geometry(size: photo.fullSize)
        setCrop(rect: geometry.swappedOrientation(settings.effectiveRect(size: photo.fullSize)))
    }

    /// Picking a ratio while cropping fills the largest crop of it, as Lightroom does; Free keeps what was shown.
    func cropAspectChanged(from old: CropAspect) {
        guard isCropping, let photo, var settings = cropSettings else { return }
        let size = photo.fullSize
        let picked = settings.aspect
        settings.aspect = old
        let shown = settings.effectiveRect(size: size)
        guard let ratio = picked.ratio(size: size, rect: shown) else {
            setCrop(rect: shown)
            return
        }
        setCrop(rect: settings.geometry(size: size).largest(ratio: ratio, around: CGPoint(x: shown.midX, y: shown.midY)))
    }
}
