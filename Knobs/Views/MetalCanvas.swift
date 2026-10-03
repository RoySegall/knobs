import CoreImage
import KnobsKit
import QuartzCore
import SwiftUI

/// Renders the preview straight into a Metal layer on its own thread. No CGImage, no CPU readback,
/// and Core Image's per-frame setup (heavy for RAW) never blocks the main thread's mouse handling.
struct MetalCanvas: NSViewRepresentable {
    let image: CIImage?
    let engine: RenderEngine
    /// Drawable size in pixels, minus padding, so the preview session can match it.
    let onViewportChange: (CGSize) -> Void

    static let padding: CGFloat = 20
    static let background = CIColor(red: 0.09, green: 0.09, blue: 0.09)

    /// Where the canvas draws an image of `imageExtent` in a view of `viewSize` points. Overlays map through
    /// this so they land on the same pixels the drawable shows.
    static func layout(imageExtent: CGRect, viewSize: CGSize, displayScale: CGFloat) -> CanvasLayout {
        CanvasLayout.fit(
            imageSize: imageExtent.size,
            drawableSize: CGSize(width: viewSize.width * displayScale, height: viewSize.height * displayScale),
            padding: padding * displayScale
        )
    }

    func makeNSView(context: Context) -> CanvasLayerView {
        CanvasLayerView(renderer: CanvasRenderer(engine: engine))
    }

    func updateNSView(_ view: CanvasLayerView, context: Context) {
        view.onViewportChange = onViewportChange
        view.show(image: image)
    }
}

final class CanvasLayerView: NSView {
    var onViewportChange: (CGSize) -> Void = { _ in }
    private let renderer: CanvasRenderer
    private var reportedViewport = CGSize.zero

    init(renderer: CanvasRenderer) {
        self.renderer = renderer
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func makeBackingLayer() -> CALayer {
        renderer.layer
    }

    func show(image: CIImage?) {
        renderer.submit(image: image, probe: PerfProbe.logURL == nil ? nil : PerfProbe.lastChange)
    }

    override func layout() {
        super.layout()
        resizeDrawable()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        resizeDrawable()
    }

    private func resizeDrawable() {
        let scale = window?.backingScaleFactor ?? 2
        let size = CGSize(width: (bounds.width * scale).rounded(), height: (bounds.height * scale).rounded())
        guard size.width > 0, size.height > 0 else { return }
        renderer.resize(drawableSize: size, contentsScale: scale)
        if PerfProbe.logURL != nil {
            PerfProbe.canvas = "bounds \(bounds.size) drawable \(size) backing \(scale)"
        }
        let inset = MetalCanvas.padding * 2 * scale
        let viewport = CGSize(width: max(size.width - inset, 1), height: max(size.height - inset, 1))
        guard viewport != reportedViewport else { return }
        reportedViewport = viewport
        // Layout runs mid-update; publishing state here would loop SwiftUI.
        DispatchQueue.main.async { [onViewportChange] in onViewportChange(viewport) }
    }
}

/// Draws the latest submitted image on a serial queue. Submissions that arrive while a frame renders
/// replace each other, so a fast drag never queues up stale frames.
nonisolated final class CanvasRenderer: @unchecked Sendable {
    private struct Job {
        var image: CIImage?
        var drawableSize: CGSize
        var contentsScale: CGFloat
        /// When the edit shown by this frame happened, if the perf probe is running.
        var probe: CFTimeInterval?
    }

    private enum Phase {
        case idle
        case rendering
        /// A frame is rendering and a newer job is waiting.
        case queued
    }

    let layer = CAMetalLayer()
    private let engine: RenderEngine
    private let commandQueue: any MTLCommandQueue
    private let queue = DispatchQueue(label: "knobs.canvas", qos: .userInteractive)
    private let lock = NSLock()
    private var job = Job(image: nil, drawableSize: .zero, contentsScale: 2, probe: nil)
    private var phase = Phase.idle

    init(engine: RenderEngine) {
        self.engine = engine
        commandQueue = engine.device.makeCommandQueue()!
        layer.device = engine.device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = false
        layer.colorspace = engine.displayColorSpace
        layer.isOpaque = true
        layer.maximumDrawableCount = 3
    }

    func submit(image: CIImage?, probe: CFTimeInterval?) {
        update { job in
            job.image = image
            job.probe = probe
        }
    }

    func resize(drawableSize: CGSize, contentsScale: CGFloat) {
        update { job in
            job.drawableSize = drawableSize
            job.contentsScale = contentsScale
        }
    }

    private func update(_ change: (inout Job) -> Void) {
        lock.lock()
        change(&job)
        let start = phase == .idle
        phase = start ? .rendering : .queued
        lock.unlock()
        if start {
            queue.async { self.drain() }
        }
    }

    private func drain() {
        while true {
            // Wait for a drawable before taking the job, so the frame shows the newest edit, not the
            // one that was current when the wait began.
            guard let drawable = nextDrawable() else {
                lock.lock()
                phase = .idle
                lock.unlock()
                return
            }
            lock.lock()
            let next = job
            lock.unlock()
            render(next, into: drawable)
            lock.lock()
            if phase == .queued {
                phase = .rendering
                lock.unlock()
            } else {
                phase = .idle
                lock.unlock()
                return
            }
        }
    }

    /// A drawable at the current job's size; a resize since the last frame swaps the layer's size first.
    private func nextDrawable() -> (any CAMetalDrawable)? {
        lock.lock()
        let size = job.drawableSize
        let scale = job.contentsScale
        lock.unlock()
        guard size.width > 0, size.height > 0 else { return nil }
        if layer.drawableSize != size {
            layer.drawableSize = size
            layer.contentsScale = scale
        }
        return layer.nextDrawable()
    }

    private func render(_ job: Job, into drawable: any CAMetalDrawable) {
        let started = CACurrentMediaTime()
        let size = CGSize(width: drawable.texture.width, height: drawable.texture.height)
        guard let buffer = commandQueue.makeCommandBuffer() else { return }
        let bounds = CGRect(origin: .zero, size: size)
        var frame = CIImage(color: MetalCanvas.background).cropped(to: bounds)
        if let image = job.image {
            let layout = CanvasLayout.fit(
                imageSize: image.extent.size,
                drawableSize: size,
                padding: MetalCanvas.padding * job.contentsScale
            )
            frame = Self.place(image: image, layout: layout).composited(over: frame)
        }
        let destination = CIRenderDestination(
            width: drawable.texture.width,
            height: drawable.texture.height,
            pixelFormat: layer.pixelFormat,
            commandBuffer: buffer
        ) { drawable.texture }
        destination.colorSpace = engine.displayColorSpace
        _ = try? engine.context.startTask(toRender: frame, to: destination)
        buffer.present(drawable)
        if let changedAt = job.probe {
            let cpu = (CACurrentMediaTime() - started) * 1000
            buffer.addCompletedHandler { buffer in
                let gpu = (buffer.gpuEndTime - buffer.gpuStartTime) * 1000
                let latency = (buffer.gpuEndTime - changedAt) * 1000
                DispatchQueue.main.async { PerfProbe.record(frame: PerfProbe.Frame(cpu: cpu, gpu: gpu, latency: latency)) }
            }
        }
        buffer.commit()
    }

    /// The session renders at viewport size, so this is usually a pure translate; a resize in progress
    /// gets a Lanczos scale until the session catches up.
    private static func place(image: CIImage, layout: CanvasLayout) -> CIImage {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return image }
        var placed = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
        if layout.scale < 1 {
            placed = placed.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: layout.scale, kCIInputAspectRatioKey: 1])
        } else if layout.scale > 1 {
            placed = placed.transformed(by: CGAffineTransform(scaleX: layout.scale, y: layout.scale))
        }
        return placed.transformed(by: CGAffineTransform(translationX: layout.frame.minX, y: layout.frame.minY))
    }
}
