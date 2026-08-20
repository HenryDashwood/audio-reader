import Foundation
import Testing

@testable import Hearful

/// Records search queries; every other method is unused here.
private final class SearchAPI: HearfulAPIProtocol, @unchecked Sendable {
    var reportedAttempts: [[String: any Sendable]] = []
    func reportVoiceAttempt(_ event: [String: any Sendable], traceparent: String? = nil) async throws {
        reportedAttempts.append(event)
    }

    func reportDiagnostic(_ event: [String: any Sendable]) async throws {}

    var results: [PodcastResult] = []
    var episodeResults: [Episode] = []
    var webResult: PodcastResult?
    var error: Error?
    private(set) var queries: [String] = []
    private(set) var episodeQueries: [String] = []
    private(set) var webQueries: [String] = []

    func searchPodcasts(query: String) async throws -> [PodcastResult] {
        queries.append(query)
        if let error { throw error }
        return results
    }

    func searchLibraryEpisodes(query: String) async throws -> [Episode] {
        episodeQueries.append(query)
        if let error { throw error }
        return episodeResults
    }

    func searchPublicationOnWeb(query: String) async throws -> PodcastResult? {
        webQueries.append(query)
        if let error { throw error }
        return webResult
    }

    func command(
        transcript: String, nowPlayingEpisodeID: Int? = nil, turns: [ConversationTurn] = [],
        traceparent: String? = nil
    ) async throws
        -> CommandResponse {
        CommandResponse(action: .unknown, spokenResponse: "?", episode: nil)
    }
    func episode(id: Int) async throws -> Episode { throw APIError(underlying: "unused") }
    func articleText(episodeID: Int) async throws -> EpisodeText {
        throw APIError(underlying: "unused")
    }
    func recentEpisodes(limit: Int) async throws -> [Episode] { [] }
    func shows() async throws -> [Show] { [] }
    func episodes(showID: Int, query: String? = nil) async throws -> [Episode] { [] }
    func login(appleIdentityToken: String, authorizationCode: String?) async throws
        -> AuthResponse
    {
        AuthResponse(token: "t", user: UserInfo(id: "u", displayName: nil))
    }
    func logout() async throws {}
    func deleteAccount() async throws {}
    func me() async throws -> UserInfo { UserInfo(id: "u", displayName: nil) }
    func reportPosition(episodeID: Int, seconds: Double, completed: Bool) async throws {}
    func setEpisodeState(episodeID: Int, played: Bool?, dismissed: Bool?) async throws {}
    func previewFeed(url: URL) async throws -> FeedPreview { throw APIError(underlying: "unused") }
    func subscribe(feedURL: URL) async throws -> Show { throw APIError(underlying: "unused") }
    func unsubscribe(showID: Int) async throws {}
}

private func result(_ title: String) -> PodcastResult {
    PodcastResult(
        title: title, feedURL: URL(string: "https://feeds.example.com/x")!,
        publisher: nil, episodeCount: nil, artworkURL: nil)
}

/// Waits for the debounce window plus the request to settle.
@MainActor
private func settle() async {
    try? await Task.sleep(for: .milliseconds(120))
}

/// Polls until the state leaves .searching: a fixed sleep is flaky when the
/// test host is under load.
@MainActor
private func settleUntilDone(_ model: PodcastSearchModel) async {
    for _ in 0..<200 {
        switch model.state {
        case .idle, .searching:
            try? await Task.sleep(for: .milliseconds(10))
        case .loaded, .failed:
            return
        }
    }
}

@MainActor
@Suite("Podcast search model")
struct PodcastSearchModelTests {
    private func makeModel(_ api: SearchAPI) -> PodcastSearchModel {
        PodcastSearchModel(api: api, debounce: .milliseconds(40))
    }

    @Test func typingBurstBecomesOneRequest() async {
        let api = SearchAPI()
        api.results = [result("The Rest Is History")]
        let model = makeModel(api)

        model.queryChanged("r")
        model.queryChanged("re")
        model.queryChanged("rest is history")
        await settleUntilDone(model)

        #expect(api.queries == ["rest is history"])
        #expect(api.episodeQueries == ["rest is history"])
        #expect(model.state == .loaded)
        #expect(model.podcasts == [result("The Rest Is History")])
    }

    @Test func searchNowSkipsTheDebounce() async {
        let api = SearchAPI()
        let model = makeModel(api)

        model.searchNow(for: "in our time")
        await settleUntilDone(model)

        #expect(api.queries == ["in our time"])
    }

    @Test func clearingAbandonsThePendingSearch() async {
        let api = SearchAPI()
        let model = makeModel(api)

        model.queryChanged("rest")
        model.clear()
        await settle()

        #expect(api.queries.isEmpty)
        #expect(model.state == .idle)
    }

    @Test func emptyQueryReturnsToIdleWithoutSearching() async {
        let api = SearchAPI()
        let model = makeModel(api)

        model.queryChanged("rest")
        model.queryChanged("")
        await settle()

        #expect(api.queries.isEmpty)
        #expect(model.state == .idle)
    }

    @Test func failureIsSpeakable() async {
        let api = SearchAPI()
        api.error = APIError(
            spokenResponse: "I cannot reach the internet right now.", underlying: "offline")
        let model = makeModel(api)

        model.searchNow(for: "rest")
        await settleUntilDone(model)

        #expect(model.state == .failed("I cannot reach the internet right now."))
    }

    @Test func libraryEpisodesAndDirectoryResultsAreKeptSeparately() async {
        let api = SearchAPI()
        api.results = [result("The Rest Is History")]
        api.episodeResults = [episode("Agincourt")]
        let model = makeModel(api)

        model.searchNow(for: "agincourt")
        await settleUntilDone(model)

        #expect(model.podcasts.map(\.title) == ["The Rest Is History"])
        #expect(model.episodes.map(\.title) == ["Agincourt"])
    }

    @Test func explicitWebSearchIsNeverTriggeredByTyping() async {
        let api = SearchAPI()
        api.webResult = result("Notes on Progress")
        let model = makeModel(api)

        model.searchNow(for: "notes on progress")
        await settleUntilDone(model)
        #expect(api.webQueries.isEmpty)

        model.searchWebNow(for: "notes on progress")
        for _ in 0..<100 where model.isSearchingWeb {
            try? await Task.sleep(for: .milliseconds(10))
        }

        #expect(api.webQueries == ["notes on progress"])
        #expect(model.webPublication?.title == "Notes on Progress")
    }
}

private func episode(_ title: String) -> Episode {
    Episode(
        id: 1,
        title: title,
        description: nil,
        author: nil,
        feedTitle: "History Show",
        audioURL: URL(string: "https://cdn.example.com/1.mp3"),
        durationSeconds: nil,
        publishedAt: nil,
        link: nil,
        imageURL: nil,
        positionSeconds: nil,
        completed: nil,
        dismissed: nil,
        hasText: nil)
}

@Suite("Local show search")
struct LocalShowSearchTests {
    private let shows = [
        Show(
            id: 1,
            title: "The Rest Is History",
            description: "World history",
            artworkURL: nil,
            episodeCount: 10,
            isArticleFeed: false,
            isFailing: false),
        Show(
            id: 2,
            title: "Café Europa",
            description: "Politics from the continent",
            artworkURL: nil,
            episodeCount: 5,
            isArticleFeed: false,
            isFailing: false),
    ]

    @Test func aTranspositionStillFindsTheShow() {
        #expect(showsMatching(shows, query: "hsitory").map(\.id) == [1])
    }

    @Test func accentsAndDescriptionsAreSearchable() {
        #expect(showsMatching(shows, query: "cafe").map(\.id) == [2])
        #expect(showsMatching(shows, query: "politics continent").map(\.id) == [2])
    }
}
