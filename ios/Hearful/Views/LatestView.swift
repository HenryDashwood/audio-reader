import SwiftUI

/// Newest episodes across every subscription — the "what's new?" question,
/// answered visually.
struct LatestView: View {
    @StateObject private var model = LatestModel()
    @ObservedObject private var player = PlaybackCoordinator.shared
    @Binding var showingVoice: Bool

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
        EpisodeRow(episode: episode, isCurrent: player.currentEpisode?.id == episode.id)
            .contentShape(Rectangle())
            .onTapGesture { try? player.play(episode) }
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
        api: HearfulAPIProtocol = HearfulAPI(baseURL: AppConfiguration.apiBaseURL),
        cache: OfflineCache = .shared
    ) {
        self.api = api
        self.cache = cache
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
