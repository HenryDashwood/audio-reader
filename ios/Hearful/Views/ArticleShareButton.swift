import SwiftUI

/// Link sharing stays immediate. PDF export uses the exact reader selection,
/// then supplies a local file to the native share pane.
struct ArticleShareButton: View {
    let episode: Episode
    var contentID: Int? = nil
    var textVersion: String? = nil
    var pdfReady = true
    @State private var artwork: UIImage?
    @StateObject private var export = ArticleExportModel()
    @State private var exportTask: Task<Void, Never>?

    private var offersPDF: Bool { episode.audioURL == nil }

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
        Group {
            if offersPDF, let link = episode.link {
                Menu {
                    ShareLink(item: link, subject: Text(episode.title),
                              preview: SharePreview(episode.title, image: previewImage)) {
                        Label("Share link", systemImage: "link")
                    }
                    Button("Export as PDF", systemImage: "doc") { preparePDF() }
                        .disabled(!pdfReady)
                } label: { icon }
            } else if let link = episode.link {
                ShareLink(item: link, subject: Text(episode.title),
                          preview: SharePreview(episode.title, image: previewImage)) { icon }
            } else {
                Button(action: preparePDF) { icon }.disabled(!pdfReady)
            }
        }
        .disabled(export.busy)
        .accessibilityLabel(export.busy ? "Preparing PDF" : "Share article")
        .accessibilityHint(offersPDF ? (episode.link == nil ? "Exports this article as a PDF" : "Choose a link or PDF")
                                   : "Opens the share sheet for this article’s original link")
        .accessibilityIdentifier("article-share")
        .sheet(item: Binding(get: { export.file }, set: { if $0 == nil { export.clear() } })) { file in
            ArticlePDFShareSheet(url: file.url)
        }
        .alert("Could not export PDF", isPresented: Binding(get: { export.error != nil },
            set: { if !$0 { export.clear() } })) {
            Button("Try again") { export.clear(); preparePDF() }
            Button("Cancel", role: .cancel) { export.clear() }
        } message: { Text(export.error ?? "The PDF couldn’t be prepared.") }
        .onChange(of: export.error) { _, message in
            if let message { AccessibilityNotification.Announcement(message).post() }
        }
        .onChange(of: "\(episode.id):\(contentID ?? episode.contentID ?? 0):\(textVersion ?? "")") { _, _ in
            exportTask?.cancel()
            export.clear()
        }
        .onDisappear {
            exportTask?.cancel()
            if export.file == nil { export.clear() }
        }
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

    private var icon: some View {
        Group {
            if export.busy { ProgressView() }
            else { Image(systemName: "square.and.arrow.up") }
        }.frame(width: 24, height: 24)
    }

    private func preparePDF() {
        guard !export.busy, pdfReady else { return }
        AccessibilityNotification.Announcement("Preparing PDF").post()
        exportTask = Task {
            let session = await SubscriptionSession.capture()
            guard !Task.isCancelled else { return }
            await export.prepare(episode: episode, contentID: contentID ?? episode.contentID,
                textVersion: textVersion, api: ArticleExportClient(baseURL: session.server, token: session.token),
                validSession: { await session.isCurrent() })
        }
    }
}

private struct ArticlePDFShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
