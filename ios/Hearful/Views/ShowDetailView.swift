import SwiftUI

/// One show's episodes, newest first.
struct ShowDetailView: View {
    let show: Show
    @StateObject private var model = EpisodeListModel()
    @ObservedObject private var player = PlaybackCoordinator.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                HStack(alignment: .top, spacing: 14) {
                    Artwork(url: show.artworkURL, size: 88)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(show.title).font(.title3.weight(.semibold))
                        Text("\(show.episodeCount) episodes")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                if let description = show.description, !description.isEmpty {
                    Text(description).font(.callout).foregroundStyle(.secondary)
                }
                unsubscribeRow
            }

            Section("Episodes") {
                if model.isOffline {
                    Label("Offline — showing saved episodes", systemImage: "wifi.slash")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                switch model.state {
                case .loading:
                    HStack { Spacer(); ProgressView(); Spacer() }
                case .failed(let message):
                    Text(message).foregroundStyle(.secondary)
                case .loaded(let episodes):
                    ForEach(episodes) { episode in
                        EpisodeRow(episode: episode, isCurrent: player.currentEpisode?.id == episode.id)
                            .contentShape(Rectangle())
                            .onTapGesture { try? player.play(episode) }
                            // The way back. A show's page keeps every episode,
                            // filed or not, so this is where a mistake made in
                            // the Latest list — or by voice — is undone.
                            .episodeFilingActions(for: episode) { filing in
                                Task { await model.file(filing, episode: episode) }
                            }
                    }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(show.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load(showID: show.id) }
        .onReceive(NotificationCenter.default.publisher(for: .hearfulEpisodeFiled)) { note in
            if let change = note.object as? EpisodeFiling.Change {
                model.filed(change)
            }
        }
    }

    /// The mirror of the preview page's Subscribe button. Unsubscribing is
    /// cheap to undo — the catalog keeps the feed and her positions — so one
    /// tap, no confirmation, same as the voice path.
    @ViewBuilder
    private var unsubscribeRow: some View {
        Button(role: .destructive) {
            Task {
                if await model.unsubscribe(showID: show.id, title: show.title) {
                    dismiss()
                }
            }
        } label: {
            if model.unsubscribing {
                ProgressView()
            } else {
                Text("Unsubscribe")
            }
        }
        .buttonStyle(.bordered)
        .disabled(model.unsubscribing)
        .accessibilityLabel("Unsubscribe from \(show.title)")
        if let message = model.unsubscribeError {
            Text(message).font(.callout).foregroundStyle(.red)
        }
    }
}

struct EpisodeRow: View {
    let episode: Episode
    var isCurrent = false

    var body: some View {
        HStack(spacing: 12) {
            Artwork(url: episode.imageURL, size: 56)
            VStack(alignment: .leading, spacing: 4) {
                Text(episode.title)
                    .font(.body.weight(isCurrent ? .semibold : .regular))
                    .lineLimit(2)
                HStack(spacing: 6) {
                    if let published = episode.publishedAt {
                        Text(published, format: .dateTime.day().month(.abbreviated))
                    }
                    if let length = formatLength(seconds: episode.durationSeconds) {
                        Text("·")
                        Text(length)
                    } else if episode.isArticle {
                        Text("·")
                        Label("Article", systemImage: "doc.plaintext")
                            .labelStyle(.titleAndIcon)
                    }
                    // Positions have been recorded all along; this is the
                    // first thing that shows them. Without it every episode
                    // looks alike, and the only way to find out whether she
                    // has heard one is to play it and listen.
                    if let progress = episode.listeningProgress.label {
                        Text("·")
                        Text(progress)
                            .foregroundStyle(
                                episode.listeningProgress == .played
                                    ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
                    }
                    // Said rather than implied. An episode she put aside is
                    // absent from the Latest list and otherwise identical to
                    // every other row here, so without this the only evidence
                    // of her having filed it is somewhere she is not looking.
                    if episode.dismissed == true {
                        Text("·")
                        Text("Not in Latest")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if let description = episode.description, !description.isEmpty {
                    Text(description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            Image(systemName: isCurrent ? "speaker.wave.2.fill" : "play.circle")
                .font(.title3)
                .foregroundStyle(isCurrent ? Color.accentColor : .secondary)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        // The hint changes with the state, because the action does: tapping a
        // half-finished episode picks it up where she left off.
        .accessibilityHint(hint)
    }

    private var hint: String {
        switch episode.listeningProgress {
        case .inProgress: "Double tap to carry on where you left off"
        case .played: "Double tap to play again from the start"
        case .unplayed: "Double tap to play"
        }
    }
}

@MainActor
final class EpisodeListModel: ObservableObject {
    enum State {
        case loading
        case loaded([Episode])
        case failed(String)
    }

    @Published private(set) var state: State = .loading
    @Published private(set) var unsubscribing = false
    @Published private(set) var unsubscribeError: String?
    /// True when the episodes on screen came from the cache rather than the
    /// network, so the view can say so.
    @Published private(set) var isOffline = false
    private let api: HearfulAPIProtocol
    private let cache: OfflineCache

    init(
        api: HearfulAPIProtocol = HearfulAPI(baseURL: AppConfiguration.apiBaseURL),
        cache: OfflineCache = .shared
    ) {
        self.api = api
        self.cache = cache
    }

    func load(showID: Int) async {
        do {
            let episodes = try await api.episodes(showID: showID)
            cache.save(episodes, for: .episodes(showID: showID))
            isOffline = false
            state = .loaded(episodes)
        } catch {
            let message = (error as? APIError)?.spokenResponse ?? "Something went wrong."
            if (error as? APIError)?.isAuthFailure != true,
                let cached = cache.load([Episode].self, for: .episodes(showID: showID)),
                !cached.isEmpty
            {
                isOffline = true
                state = .loaded(cached)
            } else {
                isOffline = false
                state = .failed(message)
            }
        }
    }

    /// Marks an episode played, puts it aside, or puts it back.
    ///
    /// The row stays — this is her whole library, not the "what's new" list —
    /// and changes its label instead, so the action she just took is visible
    /// on the thing she took it on.
    func file(_ filing: EpisodeFiling, episode: Episode) async {
        guard await fileEpisode(filing, episode, api: api) else { return }
        filed(.init(episodeID: episode.id, filing: filing))
    }

    /// The same having happened elsewhere — by voice, or from the Latest list.
    func filed(_ change: EpisodeFiling.Change) {
        guard case .loaded(let episodes) = state else { return }
        state = .loaded(
            episodes.map { episode in
                guard episode.id == change.episodeID else { return episode }
                var updated = episode
                switch change.filing {
                case .played:
                    updated.completed = true
                case .dismissed:
                    updated.dismissed = true
                case .restored:
                    updated.completed = false
                    updated.dismissed = false
                    // The backend rewinds it, and the row would otherwise go
                    // on offering to carry on from where it stopped.
                    updated.positionSeconds = 0
                }
                return updated
            })
    }

    /// True on success, so the view can pop back to the library.
    func unsubscribe(showID: Int, title: String) async -> Bool {
        guard !unsubscribing else { return false }
        unsubscribing = true
        unsubscribeError = nil
        defer { unsubscribing = false }
        do {
            try await api.unsubscribe(showID: showID)
            NotificationCenter.default.post(name: .hearfulSubscriptionsChanged, object: nil)
            AccessibilityNotification.Announcement("Unsubscribed from \(title)").post()
            return true
        } catch let error as APIError {
            unsubscribeError = error.spokenResponse
        } catch {
            unsubscribeError = "Something went wrong."
        }
        return false
    }
}
