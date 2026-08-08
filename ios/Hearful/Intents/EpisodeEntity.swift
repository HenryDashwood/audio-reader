import AppIntents
import Foundation

/// How Siri refers to an episode.
///
/// The interesting part is the query below: Siri hands us whatever she said
/// and asks us to turn it into one of these, which lets the existing backend
/// resolution — "the one about the aliens lady" — work from Siri exactly as it
/// does inside the app.
struct EpisodeEntity: AppEntity {
    let id: Int
    let title: String
    let audioURL: URL?
    let durationSeconds: Int?

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Episode")
    static let defaultQuery = EpisodeQuery()

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)")
    }

    init(id: Int, title: String, audioURL: URL?, durationSeconds: Int?) {
        self.id = id
        self.title = title
        self.audioURL = audioURL
        self.durationSeconds = durationSeconds
    }

    init(_ episode: Episode) {
        self.init(
            id: episode.id, title: episode.title, audioURL: episode.audioURL,
            durationSeconds: episode.durationSeconds)
    }

    var episode: Episode {
        Episode(
            id: id, title: title, description: nil, audioURL: audioURL,
            durationSeconds: durationSeconds, publishedAt: nil, link: nil)
    }
}

struct EpisodeQuery: EntityStringQuery {
    /// Siri asks for this when restoring an episode it resolved earlier.
    func entities(for identifiers: [Int]) async throws -> [EpisodeEntity] {
        let api = HearfulAPI(baseURL: AppConfiguration.apiBaseURL)
        var found: [EpisodeEntity] = []
        for id in identifiers {
            if let episode = try? await api.episode(id: id) {
                found.append(EpisodeEntity(episode))
            }
        }
        return found
    }

    /// Arbitrary spoken text — "the one about the aliens lady" — resolved
    /// through the same backend the in-app microphone uses. Siri calls this
    /// when it asks her what to play, rather than when matching the phrase.
    func entities(matching string: String) async throws -> [EpisodeEntity] {
        let api = HearfulAPI(baseURL: AppConfiguration.apiBaseURL)
        let response = try await api.command(transcript: "play \(string)")
        guard let episode = response.episode, episode.audioURL != nil else { return [] }
        return [EpisodeEntity(episode)]
    }

    /// Siri matches the words in a spoken phrase against *these*, not against
    /// free text — without them, "Play X on Hearful" never matches at all and
    /// the request falls through to whatever media app iOS prefers.
    func suggestedEntities() async throws -> [EpisodeEntity] {
        // The system calls this in the background, possibly before she has
        // ever signed in; an empty list is right, a thrown error is noise.
        guard HearfulAPI.tokenProvider() != nil else { return [] }
        let api = HearfulAPI(baseURL: AppConfiguration.apiBaseURL)
        return try await api.recentEpisodes(limit: 30).map(EpisodeEntity.init)
    }
}
