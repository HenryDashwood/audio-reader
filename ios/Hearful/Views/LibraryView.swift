import SwiftUI

/// The shows the user subscribes to.
struct LibraryView: View {
    @StateObject private var model = LibraryModel()
    @ObservedObject private var player = AudioPlayer.shared
    @Binding var showingVoice: Bool

    var body: some View {
        NavigationStack {
            Group {
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
                        Text("Tap the microphone and say the name of a podcast to subscribe.")
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
            .navigationTitle("Shows")
            .navigationDestination(for: Show.self) { ShowDetailView(show: $0) }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingVoice = true } label: {
                        Image(systemName: "mic.fill")
                    }
                    .accessibilityLabel("Ask for something to listen to")
                }
            }
        }
        .task { await model.load() }
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
