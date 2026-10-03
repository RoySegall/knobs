import SwiftUI

struct CanvasView: View {
    let editor: EditorModel

    var body: some View {
        ZStack {
            Color(white: 0.09)
            switch editor.state {
            case .empty:
                ContentUnavailableView("No Photo", systemImage: "photo.on.rectangle", description: Text("Open a folder with ⌘O"))
            case .loading:
                ProgressView().controlSize(.small)
            case .failed(let url, let message):
                ContentUnavailableView(url.lastPathComponent, systemImage: "exclamationmark.triangle", description: Text(message))
            case .ready:
                if let preview = editor.preview {
                    Image(decorative: preview, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .padding(20)
                } else {
                    ProgressView().controlSize(.small)
                }
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
