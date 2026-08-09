import SwiftUI

/// A show found in the directory: its episodes play immediately, and
/// subscribing is one tap — previewing already put the feed in the catalog.
struct PodcastPreviewView: View {
    let podcast: PodcastResult
    @StateObject private var model = PodcastPreviewModel()
    @ObservedObject private var player = AudioPlayer.shared

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
                            Artwork(url: preview.show.artworkURL ?? podcast.artworkURL, size: 88)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(preview.show.title).font(.title3.weight(.semibold))
                                if let publisher = podcast.publisher {
                                    Text(publisher).font(.subheadline).foregroundStyle(.secondary)
                                }
                                Text("\(preview.show.episodeCount) episodes")
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                        if let description = preview.show.description, !description.isEmpty {
                            Text(description).font(.callout).foregroundStyle(.secondary)
                        }
                        subscribeRow
                    }

                    Section("Episodes") {
                        ForEach(preview.episodes) { episode in
                            EpisodeRow(
                                episode: episode,
                                isCurrent: player.currentEpisode?.id == episode.id
                            )
                            .contentShape(Rectangle())
                            .onTapGesture { try? player.play(episode) }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle(podcast.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load(url: podcast.feedURL) }
    }

    @ViewBuilder
    private var subscribeRow: some View {
        if model.subscribed {
            Label("Subscribed", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.secondary)
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
    private let api: HearfulAPIProtocol

    init(api: HearfulAPIProtocol = HearfulAPI(baseURL: AppConfiguration.apiBaseURL)) {
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

    func subscribe(url: URL, title: String) async {
        guard !subscribed, !subscribing else { return }
        subscribing = true
        subscribeError = nil
        defer { subscribing = false }
        do {
            _ = try await api.subscribe(feedURL: url)
            subscribed = true
            NotificationCenter.default.post(name: .hearfulSubscriptionsChanged, object: nil)
            AccessibilityNotification.Announcement("Subscribed to \(title)").post()
        } catch let error as APIError {
            subscribeError = error.spokenResponse
        } catch {
            subscribeError = "Something went wrong."
        }
    }
}
