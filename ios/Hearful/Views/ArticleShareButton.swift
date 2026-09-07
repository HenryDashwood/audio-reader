import SwiftUI

/// Supplies the preview before sharing, avoiding a webpage metadata fetch as
/// the system sheet opens. The shared item remains the original article URL.
struct ArticleShareButton: View {
    let episode: Episode
    let link: URL
    @State private var artwork: UIImage?

    private var previewImage: Image {
        if let artwork {
            return Image(uiImage: artwork)
        }
        let renderer = ImageRenderer(
            content: Monogram(title: episode.feedTitle ?? episode.title, size: 120)
                .frame(width: 120, height: 120))
        renderer.scale = 2
        return Image(uiImage: renderer.uiImage ?? UIImage())
    }

    var body: some View {
        ShareLink(
            item: link,
            subject: Text(episode.title),
            preview: SharePreview(episode.title, image: previewImage)
        ) {
            Image(systemName: "square.and.arrow.up")
                .frame(width: 44, height: 44)
        }
        .accessibilityLabel("Share article")
        .accessibilityHint("Opens the share sheet for this article’s original link")
        .task(id: episode.imageURL) {
            artwork = nil
            guard let url = episode.imageURL else { return }
            do {
                let request = URLRequest(
                    url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 15)
                let (data, response) = try await URLSession.shared.data(for: request)
                guard !Task.isCancelled,
                    let response = response as? HTTPURLResponse,
                    (200..<300).contains(response.statusCode),
                    let image = UIImage(data: data)
                else { return }
                let thumbnail = await image.byPreparingThumbnail(ofSize: CGSize(width: 240, height: 240))
                guard !Task.isCancelled else { return }
                artwork = thumbnail
            } catch {
                // Sharing stays available offline or if the artwork fails.
            }
        }
    }
}
