import SwiftUI

/// The shows the user subscribes to, plus search over the public directory.
struct LibraryView: View {
    @StateObject private var model = LibraryModel()
    @StateObject private var searchModel = PodcastSearchModel()
    @ObservedObject private var player = AudioPlayer.shared
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
                    Button { showingVoice = true } label: {
                        Image(systemName: "mic.fill")
                    }
                    .accessibilityLabel("Ask for something to listen to")
                }
            }
            .searchable(text: $searchText, prompt: "Search for a podcast")
            .onSubmit(of: .search) {
                Task { await searchModel.search(for: searchText) }
            }
            .onChange(of: searchText) { _, text in
                if text.isEmpty { searchModel.clear() }
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
                Button("Add a show by voice") { showingVoice = true }
            }
        case .loaded(let shows):
            List(shows) { show in
                NavigationLink(value: show) {
                    ShowRow(show: show)
                }
            }
            .listStyle(.plain)
            .refreshable { await model.load() }
        }
    }

    @ViewBuilder
    private var searchResults: some View {
        switch searchModel.state {
        case .idle:
            ContentUnavailableView(
                "Search every podcast", systemImage: "magnifyingglass",
                description: Text("Tap Search to look up “\(searchText)”."))
        case .searching:
            ProgressView("Searching…")
        case .failed(let message):
            ContentUnavailableView(
                "Could not search", systemImage: "wifi.exclamationmark",
                description: Text(message))
        case .loaded(let results) where results.isEmpty:
            ContentUnavailableView.search(text: searchText)
        case .loaded(let results):
            List(results) { result in
                NavigationLink(value: result) {
                    PodcastResultRow(result: result)
                }
            }
            .listStyle(.plain)
        }
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
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(show.title), \(show.episodeCount) episodes")
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
    }

    @Published private(set) var state: State = .loading
    private let api: HearfulAPIProtocol

    init(api: HearfulAPIProtocol = HearfulAPI(baseURL: AppConfiguration.apiBaseURL)) {
        self.api = api
    }

    func load() async {
        do {
            let shows = try await api.shows()
            state = shows.isEmpty ? .empty : .loaded(shows)
        } catch let error as APIError {
            state = .failed(error.spokenResponse)
        } catch {
            state = .failed("Something went wrong.")
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

    init(api: HearfulAPIProtocol = HearfulAPI(baseURL: AppConfiguration.apiBaseURL)) {
        self.api = api
    }

    func search(for query: String) async {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            state = .idle
            return
        }
        state = .searching
        do {
            state = .loaded(try await api.searchPodcasts(query: query))
        } catch let error as APIError {
            state = .failed(error.spokenResponse)
        } catch {
            state = .failed("Something went wrong.")
        }
    }

    func clear() {
        state = .idle
    }
}
