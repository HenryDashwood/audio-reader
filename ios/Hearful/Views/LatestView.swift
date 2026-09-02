import SwiftUI

/// Newest episodes across every subscription — the "what's new?" question,
/// answered visually.
struct LatestView: View {
    @StateObject private var model = LatestModel()
    /// Senders waiting for a yes or no. They live on this screen because
    /// Latest is where new things arrive, and a newsletter asking to be let
    /// in is the newest thing of all.
    @StateObject private var pendingModel = PendingNewslettersModel()
    @ObservedObject private var player = PlaybackCoordinator.shared
    @Binding var showingVoice: Bool
    /// The episode whose page is open, if any.
    @Binding var openEpisode: Episode?
    @State private var confirmingClear = false
    @State private var clearError: String?

    var body: some View {
        NavigationStack {
            Group {
                switch model.state {
                case .loading:
                    ProgressView("Loading…")
                case .failed(let message):
                    ContentUnavailableView(
                        "Could not load episodes", systemImage: "wifi.exclamationmark",
                        description: Text(message))
                case .loaded(let episodes) where episodes.isEmpty && pendingModel.pending.isEmpty:
                    ContentUnavailableView(
                        "You're caught up", systemImage: "checkmark.circle",
                        description: Text("New episodes from your shows will appear here."))
                case .loaded(let episodes):
                    episodeList(episodes, offline: false)
                case .stale(let episodes):
                    episodeList(episodes, offline: true)
                }
            }
            .navigationTitle("Latest")
            // Keep the title in one place rather than changing its size and
            // alignment when the list scrolls.
            .toolbarTitleDisplayMode(.inline)
            .navigationDestination(item: $openEpisode) { episode in
                ArticleView(episode: episode) { wordCount in
                    model.learnedWordCount(wordCount, for: episode.id)
                }
            }
            .toolbar {
                if model.canClear {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            confirmingClear = true
                        } label: {
                            Label("Clear Latest", systemImage: "checkmark.circle")
                        }
                        .accessibilityHint(
                            "Removes all current items without marking them as played")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { openVoiceSheet($showingVoice) } label: {
                        Image(systemName: "mic.fill")
                    }
                    .accessibilityLabel("Ask for something to listen to")
                }
            }
            .confirmationDialog(
                "Clear Latest?",
                isPresented: $confirmingClear,
                titleVisibility: .visible
            ) {
                Button("Clear Latest", role: .destructive) {
                    Task { clearError = await model.clear() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(
                    "This removes all current items from Latest without marking them as played. "
                        + "New episodes will still appear."
                )
            }
            .alert(
                "Could not clear Latest",
                isPresented: Binding(
                    get: { clearError != nil },
                    set: { if !$0 { clearError = nil } }
                )
            ) {
                Button("OK") { clearError = nil }
            } message: {
                Text(clearError ?? "Something went wrong.")
            }
        }
        .task { await reload() }
        // Filing by voice has to move the list too: she may well be looking
        // at it — or have VoiceOver reading it — while she speaks.
        .onReceive(NotificationCenter.default.publisher(for: .hearfulEpisodeFiled)) { note in
            if let change = note.object as? EpisodeFiling.Change {
                Task { await model.filed(change) }
            }
        }
        // Following a waiting sender, here or by voice, puts its messages
        // into this list; the list has to show them without a pull.
        .onReceive(NotificationCenter.default.publisher(for: .hearfulSubscriptionsChanged)) { _ in
            Task { await reload() }
        }
    }

    private func reload() async {
        async let episodes: Void = model.load()
        async let pending: Void = pendingModel.load()
        _ = await (episodes, pending)
    }

    private func episodeList(_ episodes: [Episode], offline: Bool) -> some View {
        List {
            PendingNewslettersSection(model: pendingModel)
            if offline {
                Label("Offline — showing the last episodes we saw", systemImage: "wifi.slash")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            // Started but unfinished, lifted to the top. Otherwise the only
            // way back into a half-heard episode is to remember which show it
            // was and scroll for it — and the mini player only ever holds the
            // single most recent one.
            //
            // Moved rather than copied: a duplicated row is a small visual
            // redundancy but a real cost to anyone reading the list linearly
            // with VoiceOver, who has to swipe past the same episode twice.
            let started = episodes.filter { $0.listeningProgress.hasStarted }
            let rest = episodes.filter { !$0.listeningProgress.hasStarted }
            if started.isEmpty {
                ForEach(episodes) { row(for: $0) }
            } else {
                Section("Continue listening") {
                    ForEach(started) { row(for: $0) }
                }
                Section("Latest") {
                    ForEach(rest) { row(for: $0) }
                }
            }
        }
        .listStyle(.plain)
        .refreshable { await reload() }
    }

    private func row(for episode: Episode) -> some View {
        EpisodeRow(
            episode: episode,
            isCurrent: player.currentEpisode?.id == episode.id,
            play: { player.playReportingFailure(episode) }
        )
        .contentShape(Rectangle())
        .onTapGesture { openEpisode = episode }
        .episodeFilingActions(for: episode, allowsDismissal: true) { filing in
            Task { await model.file(filing, episode: episode) }
        }
    }
}

@MainActor
final class LatestModel: ObservableObject {
    enum State {
        case loading
        case loaded([Episode])
        case failed(String)
        /// The last answer we had, shown because a fresh one is unavailable.
        case stale([Episode])
    }

    @Published private(set) var state: State = .loading
    private let api: HearfulAPIProtocol
    private let cache: OfflineCache

    init(
        api: HearfulAPIProtocol = HearfulAPI(),
        cache: OfflineCache = .shared
    ) {
        self.api = api
        self.cache = cache
    }

    var canClear: Bool {
        switch state {
        case .loaded(let episodes), .stale(let episodes): !episodes.isEmpty
        case .loading, .failed: false
        }
    }

    /// Clears the server-side inbox boundary, then mirrors that durable empty
    /// state locally. A failed request leaves both the visible rows and cache
    /// untouched and returns a message for the view to present.
    func clear() async -> String? {
        do {
            try await api.clearLatest()
        } catch {
            return (error as? APIError)?.spokenResponse ?? "Something went wrong."
        }
        let empty: [Episode] = []
        cache.save(empty, for: .recentEpisodes)
        state = .loaded(empty)
        AccessibilityNotification.Announcement("Latest cleared").post()
        return nil
    }

    /// Marks an item played/read or dismisses it from Latest.
    ///
    /// The row goes only once the server has taken it, so a failed request
    /// leaves the list exactly as it was rather than losing an episode to a
    /// change that never happened.
    func file(_ filing: EpisodeFiling, episode: Episode) async {
        guard await fileEpisode(filing, episode, api: api) else { return }
        remove(episode.id)
    }

    /// The same thing having happened somewhere else — by voice, or on a
    /// show's page. The broadcast carries no episode, so a restore reloads.
    func filed(_ change: EpisodeFiling.Change) async {
        if change.filing.hidesFromLatest {
            remove(change.episodeID)
        } else {
            await load()
        }
    }

    /// Opening an article resolves the length that a teaser-only feed could
    /// not know when this list was fetched. Keep both the visible and offline
    /// copies in step with the text the reader has just absorbed.
    func learnedWordCount(_ wordCount: Int, for episodeID: Int) {
        switch state {
        case .loaded(let episodes):
            let updated = episodesByUpdatingWordCount(
                episodes, episodeID: episodeID, wordCount: wordCount)
            cache.save(updated, for: .recentEpisodes)
            state = .loaded(updated)
        case .stale(let episodes):
            let updated = episodesByUpdatingWordCount(
                episodes, episodeID: episodeID, wordCount: wordCount)
            cache.save(updated, for: .recentEpisodes)
            state = .stale(updated)
        case .loading, .failed:
            break
        }
    }

    /// Filed episodes are left out of the feed by the backend, so a row that
    /// has just been filed is one the next load would not return anyway.
    ///
    /// The cache is rewritten as well, because the next load may never come:
    /// out of signal, the saved copy is what she sees, and it would otherwise
    /// go on offering the episode she has just taken off her list.
    private func remove(_ episodeID: Int) {
        switch state {
        case .loaded(let episodes):
            let remaining = episodes.filter { $0.id != episodeID }
            cache.save(remaining, for: .recentEpisodes)
            state = .loaded(remaining)
        case .stale(let episodes):
            let remaining = episodes.filter { $0.id != episodeID }
            cache.save(remaining, for: .recentEpisodes)
            state = .stale(remaining)
        case .loading, .failed:
            break
        }
    }

    func load() async {
        do {
            let episodes = try await api.recentEpisodes(limit: 50)
            cache.save(episodes, for: .recentEpisodes)
            state = .loaded(episodes)
        } catch {
            let message = (error as? APIError)?.spokenResponse ?? "Something went wrong."
            if (error as? APIError)?.isAuthFailure != true,
                let cached = cache.load([Episode].self, for: .recentEpisodes)
            {
                state = .stale(cached)
            } else {
                state = .failed(message)
            }
        }
    }
}
