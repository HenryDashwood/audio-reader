import SwiftUI

/// The shows the user subscribes to, plus search over the public directory.
struct LibraryView: View {
    @StateObject private var model = LibraryModel()
    @StateObject private var searchModel = PodcastSearchModel()
    @ObservedObject private var player = PlaybackCoordinator.shared
    @Binding var showingVoice: Bool
    @State private var searchText = ""

    var body: some View {
        NavigationStack {
            Group {
                if searchText.isEmpty {
                    library
                } else {
                    searchResults
                }
            }
            .navigationTitle("Shows")
            .navigationDestination(for: Show.self) { ShowDetailView(show: $0) }
            .navigationDestination(for: PodcastResult.self) { PodcastPreviewView(podcast: $0) }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { openVoiceSheet($showingVoice) } label: {
                        Image(systemName: "mic.fill")
                    }
                    .accessibilityLabel("Ask for something to listen to")
                }
            }
            // Always visible: the default placement hides the field until a
            // pull-down, which is undiscoverable — especially by VoiceOver.
            .searchable(
                text: $searchText,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Search podcasts, or paste a feed URL")
            .onSubmit(of: .search) { searchModel.searchNow(for: searchText) }
            .onChange(of: searchText) { _, text in
                searchModel.queryChanged(text)
            }
        }
        .task { await model.load() }
        .onReceive(NotificationCenter.default.publisher(for: .hearfulSubscriptionsChanged)) { _ in
            Task { await model.load() }
        }
    }

    @ViewBuilder
    private var library: some View {
        switch model.state {
        case .loading:
            ProgressView("Loading your shows…")
        case .failed(let message):
            ContentUnavailableView(
                "Could not load your shows", systemImage: "wifi.exclamationmark",
                description: Text(message))
        case .empty:
            ContentUnavailableView {
                Label("No shows yet", systemImage: "waveform")
            } description: {
                Text(
                    "Tap the microphone and say the name of a podcast, or search for one above."
                )
            } actions: {
                Button("Add a show by voice") { openVoiceSheet($showingVoice) }
            }
        case .loaded(let shows):
            showList(shows, offline: false)
        case .stale(let shows):
            showList(shows, offline: true)
        }
    }

    private func showList(_ shows: [Show], offline: Bool) -> some View {
        List {
            if offline {
                // A row rather than a banner: VoiceOver reaches it in the same
                // swipe order as everything else, instead of it living in a
                // corner of the screen she never visits.
                Label("Offline — showing your saved shows", systemImage: "wifi.slash")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(shows) { show in
                NavigationLink(value: show) {
                    ShowRow(show: show)
                }
            }
        }
        .listStyle(.plain)
        .refreshable { await model.load() }
    }

    @ViewBuilder
    private var searchResults: some View {
        // A pasted URL is its own kind of result: any RSS/Atom feed — or a
        // site that advertises one — can be previewed and subscribed to
        // directly, no directory involved.
        let pastedFeed = pastedFeedURL(searchText).map { url in
            PodcastResult(
                title: url.host() ?? url.absoluteString,
                feedURL: url, publisher: nil, episodeCount: nil, artworkURL: nil)
        }
        switch searchModel.state {
        case .idle where pastedFeed == nil:
            ContentUnavailableView(
                "Search every podcast", systemImage: "magnifyingglass",
                description: Text("Results appear as you type."))
        case .searching where pastedFeed == nil:
            ProgressView("Searching…")
        case .failed(let message):
            ContentUnavailableView(
                "Could not search", systemImage: "wifi.exclamationmark",
                description: Text(message))
        case .loaded(let results) where results.isEmpty && pastedFeed == nil:
            ContentUnavailableView.search(text: searchText)
        default:
            List {
                if let pastedFeed {
                    Section {
                        NavigationLink(value: pastedFeed) {
                            OpenFeedRow(host: pastedFeed.title)
                        }
                    }
                }
                if case .loaded(let results) = searchModel.state {
                    ForEach(results) { result in
                        NavigationLink(value: result) {
                            PodcastResultRow(result: result)
                        }
                    }
                }
            }
            .listStyle(.plain)
        }
    }
}

/// The search text is a web address, not a show name.
///
/// Accepts full feed URLs, homepages, and bare domains ("example.com"):
/// the backend resolves a page to its advertised feed either way.
nonisolated func pastedFeedURL(_ text: String) -> URL? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !trimmed.contains(" ") else { return nil }
    let candidate =
        trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://")
        ? trimmed : "https://\(trimmed)"
    guard let url = URL(string: candidate),
        let host = url.host(),
        host.contains("."),
        // "The History Hour." is a sentence, not a domain.
        !host.hasSuffix(".")
    else { return nil }
    return url
}

private struct OpenFeedRow: View {
    let host: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "dot.radiowaves.up.forward")
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text("Open feed").font(.headline)
                Text(host).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Open the feed at \(host)")
    }
}

private struct ShowRow: View {
    let show: Show

    var body: some View {
        HStack(spacing: 12) {
            Artwork(url: show.artworkURL)
            VStack(alignment: .leading, spacing: 2) {
                Text(show.title).font(.headline).lineLimit(2)
                Text("\(show.episodeCount) episodes")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                // A show that has quietly stopped updating looks identical to
                // one that simply has nothing new. Saying so is the difference
                // between "they must be on a break" and knowing to remove it.
                if show.isFailing == true {
                    Label("Not updating", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            show.isFailing == true
                ? "\(show.title), \(show.episodeCount) episodes, not updating"
                : "\(show.title), \(show.episodeCount) episodes")
    }
}

private struct PodcastResultRow: View {
    let result: PodcastResult

    var body: some View {
        HStack(spacing: 12) {
            Artwork(url: result.artworkURL)
            VStack(alignment: .leading, spacing: 2) {
                Text(result.title).font(.headline).lineLimit(2)
                if let publisher = result.publisher {
                    Text(publisher)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            result.publisher.map { "\(result.title), by \($0)" } ?? result.title)
    }
}

@MainActor
final class LibraryModel: ObservableObject {
    enum State {
        case loading
        case loaded([Show])
        case empty
        case failed(String)
        /// The request failed but we still have the last answer. She sees her
        /// shows; the note explains why nothing is new.
        case stale([Show])
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
            let shows = try await api.shows()
            cache.save(shows, for: .shows)
            state = shows.isEmpty ? .empty : .loaded(shows)
        } catch {
            let message =
                (error as? APIError)?.spokenResponse ?? "Something went wrong."
            // An expired session is the one failure the cache must not paper
            // over: showing her library while every tap fails would be worse
            // than saying plainly that she needs to sign in.
            if (error as? APIError)?.isAuthFailure != true,
                let cached = cache.load([Show].self, for: .shows), !cached.isEmpty
            {
                state = .stale(cached)
            } else {
                state = .failed(message)
            }
        }
    }
}

@MainActor
final class PodcastSearchModel: ObservableObject {
    enum State: Equatable {
        case idle
        case searching
        case loaded([PodcastResult])
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    private let api: HearfulAPIProtocol
    private let debounce: Duration
    private var pending: Task<Void, Never>?

    /// The debounce collapses a burst of keystrokes into one request: the
    /// iTunes directory rate-limits by IP, and every keystroke as a request
    /// would trip that on a single fast typist.
    init(
        api: HearfulAPIProtocol = HearfulAPI(baseURL: AppConfiguration.apiBaseURL),
        debounce: Duration = .milliseconds(350)
    ) {
        self.api = api
        self.debounce = debounce
    }

    /// Called on every keystroke: search after a pause in typing. Existing
    /// results stay on screen until fresher ones replace them, so the list
    /// updates in place rather than flickering through a spinner.
    func queryChanged(_ query: String) {
        schedule(query, after: debounce)
    }

    /// Called from the keyboard's Search key: no waiting.
    func searchNow(for query: String) {
        schedule(query, after: .zero)
    }

    func clear() {
        pending?.cancel()
        state = .idle
    }

    private func schedule(_ query: String, after delay: Duration) {
        pending?.cancel()
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            state = .idle
            return
        }
        if case .loaded = state {} else { state = .searching }
        pending = Task {
            if delay > .zero {
                try? await Task.sleep(for: delay)
            }
            guard !Task.isCancelled else { return }
            await perform(query)
        }
    }

    private func perform(_ query: String) async {
        do {
            let results = try await api.searchPodcasts(query: query)
            guard !Task.isCancelled else { return }
            state = .loaded(results)
        } catch {
            // A newer keystroke cancelled this request; its failure is noise.
            guard !Task.isCancelled else { return }
            state = .failed(
                (error as? APIError)?.spokenResponse ?? "Something went wrong.")
        }
    }
}
