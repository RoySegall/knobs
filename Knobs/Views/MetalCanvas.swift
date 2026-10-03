import CoreImage
import KnobsKit
import MetalKit
import SwiftUI

/// Renders the preview straight into a drawable. No CGImage, no CPU readback, so a slider frame
/// costs only the plugins' GPU work.
struct MetalCanvas: NSViewRepresentable {
    let image: CIImage?
    let engine: RenderEngine
    /// Drawable size in pixels, minus padding, so the preview session can match it.
    let onViewportChange: (CGSize) -> Void

    static let padding: CGFloat = 20
    static let background = CIColor(red: 0.09, green: 0.09, blue: 0.09)

    func makeCoordinator() -> Coordinator {
        Coordinator(engine: engine)
    }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: engine.device)
        view.delegate = context.coordinator
        view.framebufferOnly = false
        view.colorPixelFormat = .bgra8Unorm
        view.colorspace = engine.displayColorSpace
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.autoResizeDrawable = true
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {
        context.coordinator.image = image
        context.coordinator.onViewportChange = onViewportChange
        view.needsDisplay = true
    }

    final class Coordinator: NSObject, MTKViewDelegate {
        var image: CIImage?
        var onViewportChange: (CGSize) -> Void = { _ in }
        private let engine: RenderEngine
        private let queue: any MTLCommandQueue

        init(engine: RenderEngine) {
            self.engine = engine
            queue = engine.device.makeCommandQueue()!
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            let inset = MetalCanvas.padding * 2 * (view.window?.backingScaleFactor ?? 2)
            let viewport = CGSize(width: max(size.width - inset, 1), height: max(size.height - inset, 1))
            // Resizes arrive mid-layout; publishing state there would loop SwiftUI.
            DispatchQueue.main.async { [onViewportChange] in onViewportChange(viewport) }
            view.needsDisplay = true
        }

        func draw(in view: MTKView) {
            guard let drawable = view.currentDrawable, let buffer = queue.makeCommandBuffer() else { return }
            let size = view.drawableSize
            let bounds = CGRect(origin: .zero, size: size)
            var frame = CIImage(color: MetalCanvas.background).cropped(to: bounds)
            if let image {
                frame = fit(image: image, in: size, padding: MetalCanvas.padding * (view.window?.backingScaleFactor ?? 2))
                    .composited(over: frame)
            }
            let destination = CIRenderDestination(
                width: Int(size.width),
                height: Int(size.height),
                pixelFormat: view.colorPixelFormat,
                commandBuffer: buffer
            ) { drawable.texture }
            destination.colorSpace = engine.displayColorSpace
            _ = try? engine.context.startTask(toRender: frame, to: destination)
            buffer.present(drawable)
            buffer.commit()
        }

        /// Centers the image on whole pixels. The session renders it at viewport size, so this is
        /// usually a pure translate; a resize in progress gets a Lanczos scale until the session catches up.
        private func fit(image: CIImage, in size: CGSize, padding: CGFloat) -> CIImage {
            let extent = image.extent
            guard extent.width > 0, extent.height > 0 else { return image }
            let scale = min((size.width - padding * 2) / extent.width, (size.height - padding * 2) / extent.height)
            var fitted = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            if abs(scale - 1) > 0.01 {
                fitted = scale < 1
                    ? fitted.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1])
                    : fitted.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            }
            let x = ((size.width - fitted.extent.width) / 2).rounded()
            let y = ((size.height - fitted.extent.height) / 2).rounded()
            return fitted.transformed(by: CGAffineTransform(translationX: x - fitted.extent.minX, y: y - fitted.extent.minY))
        }
    }
}
