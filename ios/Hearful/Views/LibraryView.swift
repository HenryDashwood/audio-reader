import SwiftUI

/// The shows the user subscribes to, plus search across her library and public
/// discovery sources.
struct LibraryView: View {
    @EnvironmentObject private var auth: AuthController
    @StateObject private var model = LibraryModel()
    @StateObject private var searchModel = PodcastSearchModel()
    @ObservedObject private var player = PlaybackCoordinator.shared
    @Binding var showingVoice: Bool
    @State private var searchText = ""
    @State private var searchScope: LibrarySearchScope = .all
    @State private var showingAIConsent = false
    @State private var openEpisode: Episode?
    @FocusState private var searchFocused: Bool

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
            .toolbarTitleDisplayMode(.inlineLarge)
            .navigationDestination(for: Show.self) { ShowDetailView(show: $0) }
            .navigationDestination(for: PodcastResult.self) { PodcastPreviewView(podcast: $0) }
            .navigationDestination(item: $openEpisode) { ArticleView(episode: $0) }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    SearchToolbarButton(
                        label: "Search shows and episodes", focused: $searchFocused)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { openVoiceSheet($showingVoice) } label: {
                        Image(systemName: "mic.fill")
                    }
                    .accessibilityLabel("Ask for something to listen to")
                }
            }
            .searchable(
                text: $searchText,
                placement: .navigationBarDrawer(displayMode: .automatic),
                prompt: "Shows, episodes, or a web address")
            .searchScopes($searchScope) {
                Text("All").tag(LibrarySearchScope.all)
                Text("Shows").tag(LibrarySearchScope.shows)
                Text("Episodes").tag(LibrarySearchScope.episodes)
            }
            .searchFocused($searchFocused)
            .onSubmit(of: .search) {
                if pastedFeedURL(searchText) == nil {
                    searchModel.searchNow(for: searchText)
                }
            }
            .onChange(of: searchText) { _, text in
                // A URL is a complete, deterministic result. It must never
                // wait on—or disappear behind—a directory request.
                if pastedFeedURL(text) != nil {
                    searchModel.clear()
                } else {
                    searchModel.queryChanged(text)
                }
            }
        }
        .task { await model.load() }
        .onReceive(NotificationCenter.default.publisher(for: .hearfulSubscriptionsChanged)) { _ in
            Task { await model.load() }
        }
        .sheet(isPresented: $showingAIConsent) {
            AIDataSharingConsentView(
                onAllowed: {
                    showingAIConsent = false
                    searchModel.searchWebNow(for: searchText)
                },
                onNotNow: { showingAIConsent = false }
            )
            .presentationDetents([.fraction(0.72), .large])
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
                Text("Tap the microphone and say the name of a podcast, or search for one above.")
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
                Label("Offline — showing your saved shows", systemImage: "wifi.slash")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(shows) { show in
                NavigationLink(value: show) { ShowRow(show: show) }
            }
        }
        .listStyle(.plain)
        .refreshable { await model.load() }
    }

    @ViewBuilder
    private var searchResults: some View {
        let pastedFeed = pastedFeedURL(searchText)
        let localShows = searchScope.includesShows
            ? showsMatching(model.availableShows, query: searchText) : []
        let localTitles = Set(localShows.map { searchIdentity($0.title) })
        let directoryResults = searchScope.includesShows
            ? searchModel.podcasts.filter { !localTitles.contains(searchIdentity($0.title)) } : []
        let episodeResults = searchScope.includesEpisodes ? searchModel.episodes : []
        let webResult = searchScope.includesShows ? searchModel.webPublication : nil
        let hasResults =
            pastedFeed != nil || !localShows.isEmpty || !directoryResults.isEmpty
            || !episodeResults.isEmpty || webResult != nil

        if let pastedFeed {
            List {
                Section {
                    NavigationLink {
                        FeedDiscoveryView(url: pastedFeed)
                    } label: {
                        OpenFeedRow(host: pastedFeed.host() ?? pastedFeed.absoluteString)
                    }
                } footer: {
                    Text("Hearful will check the address and find its RSS or Atom feed before adding it.")
                }
            }
            .listStyle(.plain)
        } else if !hasResults {
            emptySearchResults
        } else {
            List {
                if !localShows.isEmpty {
                    Section("In your library") {
                        ForEach(localShows) { show in
                            NavigationLink(value: show) { ShowRow(show: show) }
                        }
                    }
                }

                if !episodeResults.isEmpty {
                    Section("Episodes in your library") {
                        ForEach(episodeResults) { episode in
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

                if !directoryResults.isEmpty {
                    Section("Podcasts") {
                        ForEach(directoryResults) { result in
                            NavigationLink(value: result) { PodcastResultRow(result: result) }
                        }
                    }
                }

                if let webResult {
                    Section("Found on the web") {
                        NavigationLink(value: webResult) { PodcastResultRow(result: webResult) }
                    }
                }

                searchStatusRows(
                    localShows: localShows,
                    directoryResults: directoryResults,
                    episodeResults: episodeResults
                )
            }
            .listStyle(.plain)
        }
    }

    @ViewBuilder
    private var emptySearchResults: some View {
        switch searchModel.state {
        case .idle:
            ContentUnavailableView(
                "Keep typing", systemImage: "magnifyingglass",
                description: Text("Enter at least two letters, or paste a podcast or feed address."))
        case .searching:
            ProgressView("Searching your library and podcasts…")
        case .failed(let message):
            ContentUnavailableView {
                Label("Could not finish the search", systemImage: "wifi.exclamationmark")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { searchModel.searchNow(for: searchText) }
                if searchScope.includesShows { webSearchButton }
            }
        case .loaded:
            ContentUnavailableView {
                Label("No matches", systemImage: "magnifyingglass")
            } description: {
                if let message = searchModel.webMessage {
                    Text(message)
                } else {
                    Text("Nothing in your library or the podcast directory matches “\(searchText)”.")
                }
            } actions: {
                if searchScope.includesShows { webSearchButton }
            }
        }
    }

    @ViewBuilder
    private func searchStatusRows(
        localShows: [Show], directoryResults: [PodcastResult], episodeResults: [Episode]
    ) -> some View {
        if searchModel.state == .searching {
            Section { ProgressView("Updating results…") }
        }
        if let message = searchModel.noticeMessage {
            Section {
                Label(message, systemImage: "wifi.exclamationmark")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Try Again") { searchModel.searchNow(for: searchText) }
            }
        }
        if case .failed(let message) = searchModel.state {
            Section {
                Label(message, systemImage: "wifi.exclamationmark")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Try Again") { searchModel.searchNow(for: searchText) }
            }
        }
        if let message = searchModel.webMessage {
            Section { Text(message).font(.footnote).foregroundStyle(.secondary) }
        }
        if searchScope.includesShows, localShows.isEmpty, directoryResults.isEmpty,
            episodeResults.isEmpty,
            searchModel.webPublication == nil
        {
            Section { webSearchButton }
        }
    }

    private var webSearchButton: some View {
        Button {
            requestWebSearch()
        } label: {
            if searchModel.isSearchingWeb {
                ProgressView().frame(maxWidth: .infinity)
            } else {
                Label("Search the web for a publication", systemImage: "globe")
            }
        }
        .disabled(searchModel.isSearchingWeb)
        .accessibilityHint(
            "Uses AI to look for a publication that is not in the podcast directory")
    }

    private func requestWebSearch() {
        if auth.user?.aiDataSharingConsented == true {
            searchModel.searchWebNow(for: searchText)
        } else {
            showingAIConsent = true
        }
    }
}

enum LibrarySearchScope: Hashable {
    case all
    case shows
    case episodes

    var includesShows: Bool { self != .episodes }
    var includesEpisodes: Bool { self != .shows }
}

/// The search text is a web address, not a show name.
///
/// Accepts feeds, homepages, Apple Podcasts sharing links and the common
/// `itpc://`/`pcast://` feed schemes. The backend resolves every accepted
/// address and still applies its normal redirect and private-network checks.
nonisolated func pastedFeedURL(_ text: String) -> URL? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !trimmed.contains(where: { $0.isWhitespace }) else { return nil }

    let lowercased = trimmed.lowercased()
    let candidate: String
    if lowercased.hasPrefix("itpc://") {
        candidate = "https://" + trimmed.dropFirst("itpc://".count)
    } else if lowercased.hasPrefix("pcast://") {
        candidate = "https://" + trimmed.dropFirst("pcast://".count)
    } else if lowercased.hasPrefix("http://") || lowercased.hasPrefix("https://") {
        candidate = trimmed
    } else {
        candidate = "https://\(trimmed)"
    }

    guard let components = URLComponents(string: candidate),
        components.scheme == "http" || components.scheme == "https",
        components.user == nil,
        components.password == nil,
        components.port == nil || components.port == 80 || components.port == 443,
        let host = components.host,
        (host.contains(".") || host.contains(":")),
        !host.hasSuffix("."),
        let url = components.url
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
                Text("Open podcast or feed").font(.headline)
                Text(host).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Open the podcast or feed at \(host)")
    }
}

private struct ShowRow: View {
    let show: Show

    var body: some View {
        HStack(spacing: 12) {
            Artwork(url: show.artworkURL)
            VStack(alignment: .leading, spacing: 2) {
                Text(show.title).font(.headline).lineLimit(2)
                Text(show.itemCountLabel)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
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
                ? "\(show.title), \(show.itemCountLabel), not updating"
                : "\(show.title), \(show.itemCountLabel)")
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
                let details = [
                    result.primaryGenre,
                    result.episodeCount.map { "\($0) episodes" },
                ].compactMap { $0 }
                if !details.isEmpty {
                    Text(details.joined(separator: " · "))
                        .font(.caption)
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

/// Local matching remains available offline and deliberately tolerates one
/// missing, extra or transposed character in words of four letters or more.
nonisolated func showsMatching(_ shows: [Show], query: String) -> [Show] {
    let terms = searchWords(query)
    guard !terms.isEmpty else { return [] }
    return shows.filter { show in
        let words = searchWords("\(show.title) \(show.description ?? "")")
        return terms.allSatisfy { term in
            words.contains { word in
                word.hasPrefix(term) || term.hasPrefix(word) || withinOneSearchEdit(term, word)
            }
        }
    }
}

nonisolated func searchIdentity(_ value: String) -> String {
    searchWords(value).joined(separator: " ")
}

nonisolated private func searchWords(_ value: String) -> [String] {
    value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        .lowercased()
        .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        .map(String.init)
}

nonisolated private func withinOneSearchEdit(_ left: String, _ right: String) -> Bool {
    if left == right { return true }
    guard min(left.count, right.count) >= 4, abs(left.count - right.count) <= 1 else {
        return false
    }
    let left = Array(left)
    let right = Array(right)
    if left.count == right.count {
        let differences = left.indices.filter { left[$0] != right[$0] }
        if differences.count == 1 { return true }
        return differences.count == 2
            && differences[1] == differences[0] + 1
            && left[differences[0]] == right[differences[1]]
            && left[differences[1]] == right[differences[0]]
    }
    let shorter = left.count < right.count ? left : right
    let longer = left.count < right.count ? right : left
    var index = 0
    while index < shorter.count, shorter[index] == longer[index] { index += 1 }
    return Array(shorter[index...]) == Array(longer.dropFirst(index + 1))
}

@MainActor
final class LibraryModel: ObservableObject {
    enum State {
        case loading
        case loaded([Show])
        case empty
        case failed(String)
        case stale([Show])
    }

    @Published private(set) var state: State = .loading
    private let api: HearfulAPIProtocol
    private let cache: OfflineCache

    var availableShows: [Show] {
        switch state {
        case .loaded(let shows), .stale(let shows): shows
        case .loading, .empty, .failed: []
        }
    }

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
            let message = (error as? APIError)?.spokenResponse ?? "Something went wrong."
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
        case loaded
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var podcasts: [PodcastResult] = []
    @Published private(set) var episodes: [Episode] = []
    @Published private(set) var webPublication: PodcastResult?
    @Published private(set) var noticeMessage: String?
    @Published private(set) var webMessage: String?
    @Published private(set) var isSearchingWeb = false
    private let api: HearfulAPIProtocol
    private let debounce: Duration
    private var pending: Task<Void, Never>?
    private var webPending: Task<Void, Never>?
    private var activeQuery = ""

    /// One pause produces one pair of requests: a cached public-directory
    /// lookup and a search of the user's full stored episode library.
    init(
        api: HearfulAPIProtocol = HearfulAPI(baseURL: AppConfiguration.apiBaseURL),
        debounce: Duration = .milliseconds(350)
    ) {
        self.api = api
        self.debounce = debounce
    }

    func queryChanged(_ query: String) {
        schedule(query, after: debounce)
    }

    func searchNow(for query: String) {
        schedule(query, after: .zero)
    }

    func searchWebNow(for query: String) {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2 else { return }
        webPending?.cancel()
        activeQuery = query
        webPublication = nil
        webMessage = nil
        isSearchingWeb = true
        webPending = Task { [weak self] in
            await self?.performWebSearch(query)
        }
    }

    func clear() {
        pending?.cancel()
        webPending?.cancel()
        activeQuery = ""
        podcasts = []
        episodes = []
        webPublication = nil
        noticeMessage = nil
        webMessage = nil
        isSearchingWeb = false
        state = .idle
    }

    private func schedule(_ query: String, after delay: Duration) {
        pending?.cancel()
        webPending?.cancel()
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        activeQuery = query
        podcasts = []
        episodes = []
        webPublication = nil
        noticeMessage = nil
        webMessage = nil
        isSearchingWeb = false
        guard query.count >= 2 else {
            state = .idle
            return
        }
        state = .searching
        pending = Task { [weak self] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
            }
            guard !Task.isCancelled, let self else { return }
            await self.perform(query)
        }
    }

    private func perform(_ query: String) async {
        async let directoryRequest: [PodcastResult] = api.searchPodcasts(query: query)
        async let episodeRequest: [Episode] = api.searchLibraryEpisodes(query: query)

        var directoryResults: [PodcastResult]?
        var episodeResults: [Episode]?
        var failures: [String] = []
        do {
            directoryResults = try await directoryRequest
        } catch {
            failures.append(searchMessage(for: error))
        }
        do {
            episodeResults = try await episodeRequest
        } catch {
            failures.append(searchMessage(for: error))
        }

        guard !Task.isCancelled, activeQuery == query else { return }
        podcasts = directoryResults ?? []
        episodes = episodeResults ?? []
        let uniqueFailures = failures.reduce(into: [String]()) { messages, message in
            if !messages.contains(message) { messages.append(message) }
        }
        if directoryResults == nil, episodeResults == nil {
            state = .failed(uniqueFailures.joined(separator: " "))
        } else {
            noticeMessage = uniqueFailures.first
            state = .loaded
            let count = podcasts.count + episodes.count
            AccessibilityNotification.Announcement(
                count == 0 ? "No search results" : "\(count) search results"
            ).post()
        }
    }

    private func performWebSearch(_ query: String) async {
        do {
            let result = try await api.searchPublicationOnWeb(query: query)
            guard !Task.isCancelled, activeQuery == query else { return }
            webPublication = result
            webMessage = result == nil ? "No matching publication was found on the web." : nil
            AccessibilityNotification.Announcement(
                result.map { "Found \($0.title) on the web" }
                    ?? "No matching publication was found on the web"
            ).post()
        } catch {
            guard !Task.isCancelled, activeQuery == query else { return }
            webMessage = searchMessage(for: error)
            AccessibilityNotification.Announcement(webMessage ?? "Web search failed").post()
        }
        isSearchingWeb = false
    }

    private func searchMessage(for error: Error) -> String {
        (error as? APIError)?.spokenResponse ?? "Something went wrong."
    }
}
