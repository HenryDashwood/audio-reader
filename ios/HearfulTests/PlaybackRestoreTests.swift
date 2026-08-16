import Foundation
import Testing

@testable import Hearful

/// Serves one episode; records nothing else.
private final class OneEpisodeAPI: HearfulAPIProtocol, @unchecked Sendable {
    var stored: Episode?
    private(set) var requestedIDs: [Int] = []

    func episode(id: Int) async throws -> Episode {
        requestedIDs.append(id)
        guard let stored, stored.id == id else { throw APIError(underlying: "no such episode") }
        return stored
    }

    func command(transcript: String, traceparent: String? = nil) async throws -> CommandResponse {
        CommandResponse(action: .unknown, spokenResponse: "?", episode: nil)
    }
    func recentEpisodes(limit: Int) async throws -> [Episode] { [] }
    func shows() async throws -> [Show] { [] }
    func episodes(showID: Int) async throws -> [Episode] { [] }
    func login(appleIdentityToken: String, authorizationCode: String?) async throws
        -> AuthResponse
    {
        AuthResponse(token: "t", user: UserInfo(id: "u", displayName: nil))
    }
    func logout() async throws {}
    func deleteAccount() async throws {}
    func me() async throws -> UserInfo { UserInfo(id: "u", displayName: nil) }
    func reportPosition(episodeID: Int, seconds: Double, completed: Bool) async throws {}
    func articleText(episodeID: Int) async throws -> EpisodeText {
        throw APIError(underlying: "unused")
    }

    var reportedAttempts: [[String: any Sendable]] = []
    func reportVoiceAttempt(_ event: [String: any Sendable], traceparent: String? = nil) async throws {
        reportedAttempts.append(event)
    }

    func reportDiagnostic(_ event: [String: any Sendable]) async throws {}
    func searchPodcasts(query: String) async throws -> [PodcastResult] { [] }
    func previewFeed(url: URL) async throws -> FeedPreview { throw APIError(underlying: "unused") }
    func subscribe(feedURL: URL) async throws -> Show { throw APIError(underlying: "unused") }
    func unsubscribe(showID: Int) async throws {}
}

private func episode(id: Int, audio: String? = "https://cdn.example.com/e.mp3") -> Episode {
    Episode(
        id: id, title: "Episode \(id)", description: nil,
        audioURL: audio.flatMap(URL.init(string:)), durationSeconds: 3600,
        publishedAt: nil, link: nil)
}

@MainActor
@Suite("Playback restore")
struct PlaybackRestoreTests {
    private func makeDefaults() -> UserDefaults {
        let suite = "playback-restore-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func restoresTheRememberedEpisodePaused() async {
        let defaults = makeDefaults()
        PlaybackRestore.remember(episodeID: 104, defaults: defaults)
        let api = OneEpisodeAPI()
        api.stored = episode(id: 104)
        let player = PlaybackCoordinator(audio: AudioPlayer(), article: ArticlePlayer(api: api))

        await PlaybackRestore.restore(api: api, player: player, defaults: defaults)

        #expect(player.currentEpisode?.id == 104)
        #expect(!player.isPlaying)
    }

    @Test func nothingRememberedMeansNothingFetched() async {
        let api = OneEpisodeAPI()
        let player = PlaybackCoordinator(audio: AudioPlayer(), article: ArticlePlayer(api: api))

        await PlaybackRestore.restore(api: api, player: player, defaults: makeDefaults())

        #expect(api.requestedIDs.isEmpty)
        #expect(player.currentEpisode == nil)
    }

    @Test func neverReplacesWhatSheAlreadyStarted() async {
        let defaults = makeDefaults()
        PlaybackRestore.remember(episodeID: 104, defaults: defaults)
        let api = OneEpisodeAPI()
        api.stored = episode(id: 104)
        let player = PlaybackCoordinator(audio: AudioPlayer(), article: ArticlePlayer(api: api))
        player.restore(episode(id: 205))

        await PlaybackRestore.restore(api: api, player: player, defaults: defaults)

        #expect(player.currentEpisode?.id == 205)
    }

    @Test func vanishedEpisodeLeavesThePlayerEmpty() async {
        // The show may have been unsubscribed or the row deleted since.
        let defaults = makeDefaults()
        PlaybackRestore.remember(episodeID: 104, defaults: defaults)
        let api = OneEpisodeAPI()  // stored is nil: fetch throws
        let player = PlaybackCoordinator(audio: AudioPlayer(), article: ArticlePlayer(api: api))

        await PlaybackRestore.restore(api: api, player: player, defaults: defaults)

        #expect(player.currentEpisode == nil)
    }
}
