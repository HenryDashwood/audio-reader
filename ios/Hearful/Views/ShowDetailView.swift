import SwiftUI

/// One show's episodes, newest first.
struct ShowDetailView: View {
    let show: Show
    @StateObject private var model = EpisodeListModel()
    @ObservedObject private var player = AudioPlayer.shared

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
            }

            Section("Episodes") {
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
                    }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(show.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load(showID: show.id) }
    }
}

struct EpisodeRow: View {
    let episode: Episode
    var isCurrent = false

    var body: some View {
        HStack(spacing: 12) {
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
        .accessibilityHint("Double tap to play")
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
    private let api: HearfulAPIProtocol

    init(api: HearfulAPIProtocol = HearfulAPI(baseURL: AppConfiguration.apiBaseURL)) {
        self.api = api
    }

    func load(showID: Int) async {
        do {
            state = .loaded(try await api.episodes(showID: showID))
        } catch let error as APIError {
            state = .failed(error.spokenResponse)
        } catch {
            state = .failed("Something went wrong.")
        }
    }
}
