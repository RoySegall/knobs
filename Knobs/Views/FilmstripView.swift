import AppKit
import SwiftUI

struct FilmstripView: View {
    @Bindable var library: LibraryModel
    let editor: EditorModel
    let exporter: ExportModel
    @State private var trashing: URL?
    @State private var failure: String?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 6) {
                    ForEach(library.items, id: \.self) { url in
                        ThumbnailView(url: url, isSelected: url == library.selection, isEdited: library.edited.contains(url))
                            .id(url)
                            .onTapGesture { library.selection = url }
                            .contextMenu { menu(for: url) }
                    }
                }
                .padding(8)
            }
            .onChange(of: library.selection) { _, url in
                withAnimation { proxy.scrollTo(url, anchor: .center) }
            }
        }
        .frame(height: 92)
        .background(Color(white: 0.11))
        .confirmationDialog(
            "Move \(trashing?.lastPathComponent ?? "the photo") to the Trash?",
            isPresented: Binding(get: { trashing != nil }, set: { if !$0 { trashing = nil } }),
            presenting: trashing
        ) { url in
            Button("Move to Trash", role: .destructive) { trash(url) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Its edits go too. You can put both back from the Trash.")
        }
        .alert("Couldn't delete the photo", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK") {}
        } message: {
            Text(failure ?? "")
        }
    }

    @ViewBuilder
    private func menu(for url: URL) -> some View {
        Button("Export…") { exporter.present(scope: .single, photo: url) }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        Divider()
        Button("Remove from Knobs") { library.remove(url: url) }
        Button("Delete from Disk…", role: .destructive) { trashing = url }
    }

    private func trash(_ url: URL) {
        // A pending save would write the sidecar back after the photo is gone.
        if editor.openURL == url {
            editor.close(saving: false)
        }
        do {
            try library.moveToTrash(url: url)
        } catch {
            failure = error.localizedDescription
            Task { await editor.open(url: url) }
        }
    }
}

struct ThumbnailView: View {
    let url: URL
    let isSelected: Bool
    let isEdited: Bool
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            Color(white: 0.15)
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            }
        }
        .frame(width: 100, height: 76)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .overlay(RoundedRectangle(cornerRadius: 3).stroke(isSelected ? Color.accentColor : .clear, lineWidth: 2))
        .overlay(alignment: .bottomTrailing) {
            if isEdited {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 7, height: 7)
                    .overlay(Circle().stroke(.black.opacity(0.5), lineWidth: 1))
                    .padding(4)
            }
        }
        .help(url.lastPathComponent)
        .task(id: url) { image = await Thumbnails.load(url: url, maxPixelSize: 256) }
    }
}
