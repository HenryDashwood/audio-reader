import SwiftUI

/// A show found in the directory: its episodes play immediately, and
/// subscribing is one tap — previewing already put the feed in the catalog.
struct PodcastPreviewView: View {
    let podcast: PodcastResult
    @StateObject private var model: PodcastPreviewModel
    @ObservedObject private var player = PlaybackCoordinator.shared
    /// The article whose text is open, if any. Reading one does not need a
    /// subscription, any more than playing one does.
    @State private var openEpisode: Episode?

    init(podcast: PodcastResult, model: @autoclosure @escaping () -> PodcastPreviewModel = PodcastPreviewModel()) {
        self.podcast = podcast
        _model = StateObject(wrappedValue: model())
    }

    var body: some View {
        Group {
            switch model.state {
            case .loading:
                ProgressView("Loading episodes…")
            case .failed(let message):
                ContentUnavailableView(
                    "Could not load this show", systemImage: "wifi.exclamationmark",
                    description: Text(message))
            case .loaded(let preview):
                List {
                    Section {
                        HStack(alignment: .top, spacing: 14) {
                            Artwork(url: preview.show.artworkURL ?? podcast.artworkURL, title: preview.show.title, size: 88)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(preview.show.title).font(.title3.weight(.semibold))
                                if let publisher = podcast.publisher {
                                    Text(publisher).font(.subheadline).foregroundStyle(.secondary)
                                }
                                Text(preview.show.itemCountLabel)
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                        if let description = preview.show.description, !description.isEmpty {
                            Text(description).font(.callout).foregroundStyle(.secondary)
                        }
                        subscribeRow
                    }

                    Section(preview.show.itemsSectionTitle) {
                        ForEach(preview.episodes) { episode in
                            EpisodeRow(
                                episode: episode,
                                isCurrent: player.currentEpisode?.id == episode.id,
                                play: { player.playReportingFailure(episode) }
                            )
                            .contentShape(Rectangle())
                            .onTapGesture { openEpisode = episode }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle(podcast.title)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { MicToolbarButton() }
        }
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $openEpisode) { episode in
            ArticleView(episode: episode) { wordCount in
                model.learnedWordCount(wordCount, for: episode.id)
            }
        }
        .onAppear { model.isVisible = true }
        .onDisappear { model.isVisible = false }
        .task { await model.load(url: podcast.feedURL) }
    }

    @ViewBuilder
    private var subscribeRow: some View {
        if model.subscribed {
            HStack(spacing: 14) {
                Label("Subscribed", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
                Button("Unsubscribe", role: .destructive) {
                    Task { await model.unsubscribe(title: podcast.title) }
                }
                .buttonStyle(.bordered)
                .disabled(model.subscribing)
                .accessibilityLabel("Unsubscribe from \(podcast.title)")
            }
        } else {
            Button {
                Task { await model.subscribe(url: podcast.feedURL, title: podcast.title) }
            } label: {
                if model.subscribing {
                    ProgressView()
                } else {
                    Text("Subscribe")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.subscribing)
            .accessibilityLabel("Subscribe to \(podcast.title)")
        }
        if let message = model.subscribeError {
            Text(message).font(.callout).foregroundStyle(.red)
        }
    }
}

@MainActor
final class PodcastPreviewModel: ObservableObject {
    enum State {
        case loading
        case loaded(FeedPreview)
        case failed(String)
    }

    @Published private(set) var state: State = .loading
    @Published private(set) var subscribed = false
    @Published private(set) var subscribing = false
    @Published private(set) var subscribeError: String?
    var isVisible = false
    private let notifications: NotificationCenter
    private let announce: (String) -> Void
    private let api: HearfulAPIProtocol

    init(
        api: HearfulAPIProtocol = HearfulAPI(),
        notifications: NotificationCenter = .default,
        announce: @escaping (String) -> Void = { AccessibilityNotification.Announcement($0).post() }
    ) {
        self.notifications = notifications
        self.announce = announce
        self.api = api
    }

    func load(url: URL) async {
        do {
            let preview = try await api.previewFeed(url: url)
            subscribed = preview.subscribed
            state = .loaded(preview)
        } catch let error as APIError {
            state = .failed(error.spokenResponse)
        } catch {
            state = .failed("Something went wrong.")
        }
    }

    /// Preview rows use the same pre-extraction snapshots as subscribed
    /// shows, even though they have no offline list cache to update.
    func learnedWordCount(_ wordCount: Int, for episodeID: Int) {
        guard case .loaded(let preview) = state else { return }
        state = .loaded(
            FeedPreview(
                show: preview.show,
                episodes: episodesByUpdatingWordCount(
                    preview.episodes, episodeID: episodeID, wordCount: wordCount),
                subscribed: preview.subscribed))
    }

    func subscribe(url: URL, title: String) async {
        guard !subscribed, !subscribing else { return }
        subscribing = true
        subscribeError = nil
        defer { subscribing = false }
        do {
            _ = try await api.subscribe(feedURL: url)
            subscriptionChanged(to: true, title: title)
        } catch let error as APIError {
            subscribeError = error.spokenResponse
        } catch {
            subscribeError = "Something went wrong."
        }
    }

    func unsubscribe(title: String) async {
        guard subscribed, !subscribing, case .loaded(let preview) = state else { return }
        subscribing = true
        subscribeError = nil
        defer { subscribing = false }
        do {
            try await api.unsubscribe(showID: preview.show.id)
            subscriptionChanged(to: false, title: title)
        } catch let error as APIError {
            subscribeError = error.spokenResponse
        } catch {
            subscribeError = "Something went wrong."
        }
    }

    private func subscriptionChanged(to following: Bool, title: String) {
        subscribed = following
        notifications.post(name: .hearfulSubscriptionsChanged, object: nil)
        if isVisible {
            announce(following ? "Subscribed to \(title)" : "Unsubscribed from \(title)")
        }
    }
}
