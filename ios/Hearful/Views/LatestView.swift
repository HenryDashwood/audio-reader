import SwiftUI

/// Newest episodes across every subscription — the "what's new?" question,
/// answered visually.
struct LatestView: View {
    @StateObject private var model = LatestModel()
    @ObservedObject private var player = PlaybackCoordinator.shared
    @Binding var showingVoice: Bool
    /// The episode whose page is open, if any.
    @State private var openEpisode: Episode?

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
                case .loaded(let episodes) where episodes.isEmpty:
                    ContentUnavailableView(
                        "Nothing yet", systemImage: "clock",
                        description: Text("Subscribe to a show to see new episodes here."))
                case .loaded(let episodes):
                    episodeList(episodes, offline: false)
                case .stale(let episodes):
                    episodeList(episodes, offline: true)
                }
            }
            .navigationTitle("Latest")
            // Level with the search and microphone buttons rather than on a
            // line of its own below them: a large title in its own band costs
            // an inch of every screen before a single episode is shown.
            .toolbarTitleDisplayMode(.inlineLarge)
            .navigationDestination(item: $openEpisode) { ArticleView(episode: $0) }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { openVoiceSheet($showingVoice) } label: {
                        Image(systemName: "mic.fill")
                    }
                    .accessibilityLabel("Ask for something to listen to")
                }
            }
        }
        .task { await model.load() }
        // Filing by voice has to move the list too: she may well be looking
        // at it — or have VoiceOver reading it — while she speaks.
        .onReceive(NotificationCenter.default.publisher(for: .hearfulEpisodeFiled)) { note in
            if let change = note.object as? EpisodeFiling.Change {
                Task { await model.filed(change) }
            }
        }
    }

    private func episodeList(_ episodes: [Episode], offline: Bool) -> some View {
        List {
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
        .refreshable { await model.load() }
    }

    private func row(for episode: Episode) -> some View {
        EpisodeRow(
            episode: episode,
            isCurrent: player.currentEpisode?.id == episode.id,
            play: { player.playReportingFailure(episode) }
        )
        .contentShape(Rectangle())
        .onTapGesture { openEpisode = episode }
        .episodeFilingActions(for: episode) { filing in
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

    /// Marks an episode played, puts it aside, or puts it back.
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
                let cached = cache.load([Episode].self, for: .recentEpisodes), !cached.isEmpty
            {
                state = .stale(cached)
            } else {
                state = .failed(message)
            }
        }
    }
}
