import SwiftUI

struct CanvasView: View {
    let editor: EditorModel

    var body: some View {
        ZStack {
            MetalCanvas(image: editor.previewImage, engine: editor.engine) { viewport in
                editor.updateViewport(pixels: viewport)
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
