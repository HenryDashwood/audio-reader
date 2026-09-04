import Foundation
import Testing

@testable import Hearful

/// Records the filing calls and hands back a fixed list of episodes.
private final class FilingAPI: HearfulAPIProtocol, @unchecked Sendable {
    var episodes: [Episode] = []
    var failure: Error?
    var filings: [(episodeID: Int, played: Bool?, dismissed: Bool?)] = []
    var clearCount = 0

    func setEpisodeState(episodeID: Int, played: Bool?, dismissed: Bool?) async throws {
        if let failure { throw failure }
        filings.append((episodeID, played, dismissed))
    }

    func recentEpisodes(limit: Int) async throws -> [Episode] { episodes }
    func clearLatest() async throws {
        if let failure { throw failure }
        clearCount += 1
    }
    func episodes(showID: Int, query: String? = nil) async throws -> [Episode] { episodes }

    func command(
        transcript: String, nowPlayingEpisodeID: Int? = nil, turns: [ConversationTurn] = [],
        traceparent: String? = nil
    )
        async throws -> CommandResponse
    {
        CommandResponse(action: .unknown, spokenResponse: "?", episode: nil)
    }
    func episode(id: Int) async throws -> Episode { throw APIError(underlying: "unused") }
    func articleText(episodeID: Int) async throws -> EpisodeText {
        throw APIError(underlying: "unused")
    }
    func shows() async throws -> [Show] { [] }
    func searchPodcasts(query: String) async throws -> [PodcastResult] { [] }
    func previewFeed(url: URL) async throws -> FeedPreview { throw APIError(underlying: "unused") }
    func subscribe(feedURL: URL) async throws -> Show { throw APIError(underlying: "unused") }
    func unsubscribe(showID: Int) async throws {}
    func login(appleIdentityToken: String, authorizationCode: String?) async throws -> AuthResponse {
        AuthResponse(token: "t", user: UserInfo(id: "u", displayName: nil))
    }
    func logout() async throws {}
    func me() async throws -> UserInfo { UserInfo(id: "u", displayName: nil) }
    func deleteAccount() async throws {}
    func reportPosition(
        episodeID: Int, seconds: Double, completed: Bool, durationSeconds: Int?
    ) async throws {}
    func reportVoiceAttempt(_ event: [String: any Sendable], traceparent: String? = nil) async throws
    {}
    func reportDiagnostic(_ event: [String: any Sendable]) async throws {}
}

// Ids well clear of the other suites': filing broadcasts through
// NotificationCenter, the tests run in parallel, and a position reporter
// alive in another test is listening.
private func episode(id: Int, played: Bool? = nil, dismissed: Bool? = nil) -> Episode {
    Episode(
        id: id, title: "Episode \(id)", description: nil,
        audioURL: URL(string: "https://cdn.example.com/\(id).mp3"), durationSeconds: 3600,
        publishedAt: nil, link: nil, positionSeconds: nil, completed: played, dismissed: dismissed)
}

private func article(id: Int) -> Episode {
    Episode(
        id: id, title: "Article \(id)", description: nil, audioURL: nil, durationSeconds: nil,
        publishedAt: nil, link: nil, positionSeconds: nil, completed: nil, dismissed: nil,
        hasText: true)
}

private func makeCache() -> OfflineCache {
    OfflineCache(directory: URL.temporaryDirectory.appending(path: "filing-\(UUID().uuidString)"))
}

@MainActor
@Suite("Filing episodes")
struct EpisodeFilingTests {
    @Test func markingPlayedClaimsOnlyThat() async throws {
        // The two flags are independent on purpose; sending both would make
        // "I have heard this" and "take this away" the same statement again.
        let api = FilingAPI()

        _ = await fileEpisode(.played, episode(id: 7001), api: api)

        let filing = try #require(api.filings.first)
        #expect(filing.played == true)
        #expect(filing.dismissed == nil)
    }

    @Test func dismissingSaysNothingAboutListening() async throws {
        let api = FilingAPI()

        _ = await fileEpisode(.dismissed, episode(id: 7002), api: api)

        let filing = try #require(api.filings.first)
        #expect(filing.dismissed == true)
        #expect(filing.played == nil)
    }

    @Test func restoringClearsBoth() async throws {
        let api = FilingAPI()

        _ = await fileEpisode(.restored, episode(id: 7003), api: api)

        let filing = try #require(api.filings.first)
        #expect(filing.played == false)
        #expect(filing.dismissed == false)
    }

    @Test func aFailedRequestChangesNothing() async {
        let api = FilingAPI()
        api.failure = APIError(underlying: "offline")

        let changed = await fileEpisode(.played, episode(id: 7004), api: api)

        #expect(changed == false)
    }

    @Test func anAlreadyFiledEpisodeOffersMarkAsUnplayed() {
        #expect(
            EpisodeFiling.available(
                for: episode(id: 7005, played: true), allowsDismissal: false) == [.restored])
        #expect(
            EpisodeFiling.available(
                for: episode(id: 7006, dismissed: true), allowsDismissal: false) == [.restored])
    }

    @Test func latestSwipesDismissLeadingAndMarkReadTrailing() {
        let unread = article(id: 7010)

        #expect(
            EpisodeFiling.leadingSwipeActions(
                for: unread, allowsDismissal: true) == [.dismissed])
        #expect(
            EpisodeFiling.trailingSwipeActions(
                for: unread, allowsDismissal: true) == [.played])
    }

    @Test func showPageHasNoDismissSwipe() {
        let unplayed = episode(id: 7011)

        #expect(
            EpisodeFiling.leadingSwipeActions(
                for: unplayed, allowsDismissal: false).isEmpty)
        #expect(
            EpisodeFiling.trailingSwipeActions(
                for: unplayed, allowsDismissal: false) == [.played])
    }

    @Test func showPageMarksAFiledEpisodeUnplayedOnTheTrailingEdge() {
        let filed = episode(id: 7012, played: true)

        #expect(
            EpisodeFiling.trailingSwipeActions(
                for: filed, allowsDismissal: false) == [.restored])
    }

    @Test func completedActionUsesReadingLanguageForArticles() {
        let post = article(id: 7008)
        let audio = episode(id: 7009)

        #expect(EpisodeFiling.played.actionTitle(for: post) == "Mark as read")
        #expect(EpisodeFiling.played.confirmation(for: post) == "Marked as read: Article 7008")
        #expect(EpisodeFiling.played.actionTitle(for: audio) == "Mark as played")
        #expect(EpisodeFiling.played.confirmation(for: audio) == "Marked as played: Episode 7009")
        #expect(EpisodeFiling.dismissed.actionTitle(for: post) == "Dismiss")
        #expect(EpisodeFiling.restored.actionTitle(for: post) == "Mark as unread")
        #expect(EpisodeFiling.restored.actionTitle(for: audio) == "Mark as unplayed")
        #expect(EpisodeFiling.restored.confirmation(for: post) == "Marked as unread: Article 7008")
        #expect(
            EpisodeFiling.restored.confirmation(for: audio) == "Marked as unplayed: Episode 7009")
    }
}

@MainActor
@Suite("Filing from the Latest list")
struct LatestFilingTests {
    private func makeModel(_ episodes: [Episode]) async -> (LatestModel, FilingAPI) {
        let api = FilingAPI()
        api.episodes = episodes
        let model = LatestModel(api: api, cache: makeCache())
        await model.load()
        return (model, api)
    }

    private func titles(_ model: LatestModel) -> [Int] {
        if case .loaded(let episodes) = model.state { return episodes.map(\.id) }
        return []
    }

    @Test func theRowGoes() async {
        // The whole visible effect of filing: the episode stops being offered.
        let (model, _) = await makeModel([episode(id: 7101), episode(id: 7102)])

        await model.file(.played, episode: episode(id: 7101))

        #expect(titles(model) == [7102])
    }

    @Test func aDismissalTakesTheRowTooo() async {
        let (model, _) = await makeModel([episode(id: 7103), episode(id: 7104)])

        await model.file(.dismissed, episode: episode(id: 7103))

        #expect(titles(model) == [7104])
    }

    @Test func aFailedRequestKeepsTheRow() async {
        // Losing an episode from her list over a change that never reached the
        // server is worse than the swipe appearing not to have worked.
        let (model, api) = await makeModel([episode(id: 7105), episode(id: 7106)])
        api.failure = APIError(underlying: "offline")

        await model.file(.played, episode: episode(id: 7105))

        #expect(titles(model) == [7105, 7106])
    }

    @Test func filingElsewhereMovesTheListToo() async {
        // She may well be looking at this list — or have VoiceOver reading
        // it — while she files something by voice.
        let (model, _) = await makeModel([episode(id: 7107), episode(id: 7108)])

        await model.filed(.init(episodeID: 7107, filing: .played))

        #expect(titles(model) == [7108])
    }

    @Test func clearingEmptiesTheWholeList() async {
        let (model, api) = await makeModel([episode(id: 7109), episode(id: 7110)])

        let error = await model.clear()

        #expect(error == nil)
        #expect(api.clearCount == 1)
        #expect(titles(model).isEmpty)
        #expect(!model.canClear)
    }

    @Test func aFailedClearKeepsEveryRow() async {
        let (model, api) = await makeModel([episode(id: 7111), episode(id: 7112)])
        api.failure = APIError(underlying: "offline")

        let error = await model.clear()

        #expect(error != nil)
        #expect(titles(model) == [7111, 7112])
    }

    @Test func openingAnArticleFillsInItsWordCountAndSavedRow() async {
        let cache = makeCache()
        let api = FilingAPI()
        api.episodes = [article(id: 7113)]
        let model = LatestModel(api: api, cache: cache)
        await model.load()

        model.learnedWordCount(842, for: 7113)

        guard case .loaded(let episodes) = model.state else {
            Issue.record("expected loaded episodes")
            return
        }
        #expect(episodes.first?.wordCount == 842)
        #expect(
            cache.load([Episode].self, for: .recentEpisodes)?.first?.wordCount == 842)
    }
}

@MainActor
@Suite("Filing from a show's page")
struct ShowPageFilingTests {
    private func makeModel(_ episodes: [Episode]) async -> (EpisodeListModel, FilingAPI) {
        let api = FilingAPI()
        api.episodes = episodes
        let model = EpisodeListModel(api: api, cache: makeCache())
        await model.load(showID: 1)
        return (model, api)
    }

    private func first(_ model: EpisodeListModel) -> Episode? {
        if case .loaded(let episodes) = model.state { return episodes.first }
        return nil
    }

    @Test func theRowStaysAndSaysSo() async {
        // A show's page is her library, not the "what's new" list: the episode
        // stays where she can find it, wearing the label she just gave it.
        let (model, _) = await makeModel([episode(id: 7201)])

        await model.file(.played, episode: episode(id: 7201))

        #expect(first(model)?.completed == true)
        #expect(first(model)?.dismissed != true)
    }

    @Test func aDismissedEpisodeIsNotMarkedHeard() async {
        let (model, _) = await makeModel([episode(id: 7202)])

        await model.file(.dismissed, episode: episode(id: 7202))

        #expect(first(model)?.dismissed == true)
        #expect(first(model)?.completed != true)
    }

    @Test func restoringRewindsItToo() async {
        // The backend rewinds a restored episode; a row still holding the old
        // position would go on offering to carry on from near the end.
        let (model, _) = await makeModel([
            Episode(
                id: 7203, title: "Episode", description: nil,
                audioURL: URL(string: "https://cdn.example.com/7203.mp3"), durationSeconds: 3600,
                publishedAt: nil, link: nil, positionSeconds: 3400, completed: true)
        ])

        await model.file(.restored, episode: episode(id: 7203))

        #expect(first(model)?.completed == false)
        #expect(first(model)?.positionSeconds == 0)
        #expect(first(model)?.listeningProgress == .unplayed)
    }

    @Test func openingAnArticleFillsInItsWordCountAndSavedRow() async {
        let cache = makeCache()
        let api = FilingAPI()
        api.episodes = [article(id: 7204)]
        let model = EpisodeListModel(api: api, cache: cache)
        await model.load(showID: 1)

        model.learnedWordCount(913, for: 7204, showID: 1)

        #expect(first(model)?.wordCount == 913)
        #expect(
            cache.load([Episode].self, for: .episodes(showID: 1))?.first?.wordCount == 913)
    }
}
