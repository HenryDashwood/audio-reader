import SwiftUI

/// One show's episodes, newest first.
struct ShowDetailView: View {
    let show: Show
    @StateObject private var model = EpisodeListModel()
    @ObservedObject private var player = PlaybackCoordinator.shared
    @Environment(\.dismiss) private var dismiss
    /// The episode whose page is open, if any.
    @State private var openEpisode: Episode?
    @State private var searchText = ""
    @FocusState private var searchFocused: Bool

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

            Section(model.isSearching ? "Results" : "Episodes") {
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
                // Said rather than shown as an empty list: a search that found
                // nothing and a show still loading look identical otherwise,
                // and under VoiceOver both are simply silence.
                case .loaded(let episodes) where episodes.isEmpty && model.isSearching:
                    Text("Nothing in \(show.title) matches “\(searchText)”.")
                        .foregroundStyle(.secondary)
                case .loaded(let episodes):
                    ForEach(episodes) { episode in
                        EpisodeRow(
                            episode: episode,
                            isCurrent: player.currentEpisode?.id == episode.id,
                            play: { try? player.play(episode) }
                        )
                        .contentShape(Rectangle())
                        .onTapGesture { openEpisode = episode }
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
        // No title in the bar: the show's name is the first thing on the page
        // already, in the header a few points below it.
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $openEpisode) { ArticleView(episode: $0) }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                MicToolbarButton()
            }
            ToolbarItem(placement: .topBarTrailing) {
                SearchToolbarButton(label: "Search this show", focused: $searchFocused)
            }
        }
        // Hidden until a pull-down, like the library's. Two reasons: the
        // episodes arrive after the page does, and a field pinned under the
        // title restyles itself the moment the list grows long enough to
        // scroll — a flicker on every visit; and the page is less cluttered
        // without it. The toolbar button above is what keeps it findable.
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .automatic),
            prompt: "Search this show")
        .searchFocused($searchFocused)
        .onChange(of: searchText) { _, text in
            model.queryChanged(text, showID: show.id)
        }
        .onSubmit(of: .search) { model.searchNow(searchText, showID: show.id) }
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
    /// Starts it, from the row, without going to its page first.
    ///
    /// Tapping the row itself opens the episode — its text, its notes, what it
    /// is about — because that is the question a list of titles usually
    /// raises, and hearing it is a decision made after reading one. But
    /// listening is what the app is for, so it keeps a button of its own here
    /// rather than becoming two taps away.
    var play: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            summary
            if let play {
                Button(action: play) {
                    Image(systemName: isCurrent ? "speaker.wave.2.fill" : "play.circle")
                        .font(.title3)
                        .foregroundStyle(isCurrent ? Color.accentColor : .secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                // .plain so the button claims only its own glyph; a bordered
                // button inside a List row swallows the whole row's taps.
                .buttonStyle(.plain)
                .accessibilityLabel(playLabel)
                .accessibilityHint(hint)
            }
        }
        .padding(.vertical, 2)
    }

    private var playLabel: String {
        isCurrent ? "Playing \(episode.title)" : "Play \(episode.title)"
    }

    private var summary: some View {
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
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Double tap to open this episode")
    }

    /// The hint changes with the state, because the action does: playing a
    /// half-finished episode picks it up where she left off.
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
    /// True when the list on screen answers a search rather than being the
    /// show. The difference matters to what an empty list means.
    @Published private(set) var isSearching = false
    private let api: HearfulAPIProtocol
    private let cache: OfflineCache
    private let debounce: Duration
    /// The search in flight, including the pause before it starts. Not private
    /// so tests can await it: sleeping for longer than the debounce instead
    /// passes on a quiet machine and fails on a loaded one, which is the worst
    /// kind of test — it fails for people who did not touch this code.
    private(set) var pending: Task<Void, Never>?

    /// The debounce collapses a burst of keystrokes into one request, the same
    /// reason as the directory search: each one is a database scan across a
    /// whole archive, and a fast typist would start a dozen of them.
    init(
        api: HearfulAPIProtocol = HearfulAPI(baseURL: AppConfiguration.apiBaseURL),
        cache: OfflineCache = .shared,
        debounce: Duration = .milliseconds(300)
    ) {
        self.api = api
        self.cache = cache
        self.debounce = debounce
    }

    func load(showID: Int) async {
        await fetch(showID: showID, query: nil)
    }

    /// Called on every keystroke: search after a pause in typing.
    func queryChanged(_ query: String, showID: Int) {
        schedule(query, showID: showID, after: debounce)
    }

    /// Called from the keyboard's Search key: no waiting.
    func searchNow(_ query: String, showID: Int) {
        schedule(query, showID: showID, after: .zero)
    }

    private func schedule(_ query: String, showID: Int, after delay: Duration) {
        pending?.cancel()
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // Existing rows stay on screen until fresher ones replace them, so the
        // list updates in place rather than flickering through a spinner.
        pending = Task { [weak self] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
            }
            guard !Task.isCancelled else { return }
            await self?.fetch(showID: showID, query: query.isEmpty ? nil : query)
        }
    }

    private func fetch(showID: Int, query: String?) async {
        do {
            let episodes = try await api.episodes(showID: showID, query: query)
            guard !Task.isCancelled else { return }
            // Only the whole show is worth keeping. Writing a result set here
            // would leave the cache holding three episodes about volcanoes and
            // call them the show — and the next time she opened it with no
            // signal, that is what she would get.
            if query == nil {
                cache.save(episodes, for: .episodes(showID: showID))
            }
            isSearching = query != nil
            isOffline = false
            state = .loaded(episodes)
        } catch {
            guard !Task.isCancelled else { return }
            let message = (error as? APIError)?.spokenResponse ?? "Something went wrong."
            isSearching = query != nil
            // A search that cannot reach the network falls back to nothing
            // rather than to the cached show: answering "what have you got
            // about Krakatoa?" with the last fifty episodes is not a worse
            // answer, it is a different question.
            if query == nil, (error as? APIError)?.isAuthFailure != true,
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
