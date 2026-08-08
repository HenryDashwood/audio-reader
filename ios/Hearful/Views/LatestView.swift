import SwiftUI

/// Newest episodes across every subscription — the "what's new?" question,
/// answered visually.
struct LatestView: View {
    @StateObject private var model = LatestModel()
    @ObservedObject private var player = AudioPlayer.shared
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
                    List(episodes) { episode in
                        EpisodeRow(episode: episode, isCurrent: player.currentEpisode?.id == episode.id)
                            .contentShape(Rectangle())
                            .onTapGesture { try? player.play(episode) }
                    }
                    .listStyle(.plain)
                    .refreshable { await model.load() }
                }
            }
            .navigationTitle("Latest")
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

@MainActor
final class LatestModel: ObservableObject {
    enum State {
        case loading
        case loaded([Episode])
        case failed(String)
    }

    @Published private(set) var state: State = .loading
    private let api: HearfulAPIProtocol

    init(api: HearfulAPIProtocol = HearfulAPI(baseURL: AppConfiguration.apiBaseURL)) {
        self.api = api
    }

    func load() async {
        do {
            state = .loaded(try await api.recentEpisodes(limit: 50))
        } catch let error as APIError {
            state = .failed(error.spokenResponse)
        } catch {
            state = .failed("Something went wrong.")
        }
    }
}
