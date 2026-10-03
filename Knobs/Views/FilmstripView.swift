import SwiftUI

struct FilmstripView: View {
    @Bindable var library: LibraryModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 6) {
                    ForEach(library.items, id: \.self) { url in
                        ThumbnailView(url: url, isSelected: url == library.selection, isEdited: library.edited.contains(url))
                            .id(url)
                            .onTapGesture { library.selection = url }
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
