import SwiftUI

struct CanvasView: View {
    let editor: EditorModel
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        ZStack {
            MetalCanvas(image: editor.previewImage, engine: editor.engine) { viewport in
                editor.updateViewport(pixels: viewport)
            }
            if editor.isCropping, editor.compare == .edited, let image = editor.previewImage, let photo = editor.photo,
               let settings = editor.cropSettings {
                GeometryReader { proxy in
                    CropOverlay(
                        editor: editor,
                        settings: settings,
                        photoSize: photo.fullSize,
                        layout: MetalCanvas.layout(imageExtent: image.extent, viewSize: proxy.size, displayScale: displayScale),
                        displayScale: displayScale
                    )
                }
            }
            if editor.isEditingGradient, editor.compare == .edited, let image = editor.previewImage,
               let gradient = editor.gradient {
                GeometryReader { proxy in
                    GradientOverlay(
                        editor: editor,
                        gradient: gradient,
                        layout: MetalCanvas.layout(imageExtent: image.extent, viewSize: proxy.size, displayScale: displayScale),
                        displayScale: displayScale
                    )
                }
            }
            switch editor.state {
            case .empty:
                ContentUnavailableView("No Photo", systemImage: "photo.on.rectangle", description: Text("Open a folder with ⌘O"))
            case .loading:
                ProgressView().controlSize(.small)
            case .failed(let url, let message):
                ContentUnavailableView(url.lastPathComponent, systemImage: "exclamationmark.triangle", description: Text(message))
            case .ready:
                EmptyView()
            }
        }
        .overlay(alignment: .topLeading) {
            if editor.compare == .original {
                Text("Before")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.6), in: Capsule())
                    .padding(12)
            }
        }
    }
}
