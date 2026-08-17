import Foundation
import Testing

@testable import Hearful

private func makeCache() -> OfflineCache {
    let directory = URL.temporaryDirectory.appending(path: "article-tests-\(UUID().uuidString)")
    return OfflineCache(directory: directory)
}

private let article = """
    The first paragraph, which is short.

    The second paragraph, which is also short.
    """

@Suite("Article reader")
@MainActor
struct ArticleReaderTests {
    @Test func blankLinesDoNotBecomeEmptyParagraphs() async {
        let api = FakeAPI()
        api.articleText = "One.\n\n\n\nTwo.\n"
        let model = ArticleTextModel(api: api, cache: makeCache())

        await model.load(episodeID: 1)

        guard case .loaded(let loaded) = model.state else {
            Issue.record("expected the article, got \(model.state)")
            return
        }
        #expect(loaded.body == "<p>One.</p><p>Two.</p>")
    }

    @Test func aSuccessfulLoadIsCached() async {
        let cache = makeCache()
        let api = FakeAPI()
        api.articleText = article
        let model = ArticleTextModel(api: api, cache: cache)

        await model.load(episodeID: 7)

        #expect(cache.load(EpisodeText.self, for: .articleText(episodeID: 7))?.text == article)
        #expect(model.isOffline == false)
    }

    @Test func aFailureShowsTheSavedCopy() async {
        let cache = makeCache()
        cache.save(
            EpisodeText(episodeID: 7, title: "An article", text: article),
            for: .articleText(episodeID: 7))
        let api = FakeAPI()
        api.articleTextError = APIError(underlying: "offline")
        let model = ArticleTextModel(api: api, cache: cache)

        await model.load(episodeID: 7)

        guard case .loaded(let loaded) = model.state else {
            Issue.record("expected the saved copy, got \(model.state)")
            return
        }
        #expect(loaded.body.contains("The first paragraph"))
        #expect(loaded.body.contains("The second paragraph"))
        // Said out loud, because the article on screen is otherwise
        // indistinguishable from a fresh copy.
        #expect(model.isOffline)
    }

    @Test func eachArticleIsSavedSeparately() async {
        let cache = makeCache()
        cache.save(
            EpisodeText(episodeID: 7, title: "An article", text: article),
            for: .articleText(episodeID: 7))
        let api = FakeAPI()
        api.articleTextError = APIError(underlying: "offline")
        let model = ArticleTextModel(api: api, cache: cache)

        await model.load(episodeID: 8)

        guard case .failed = model.state else {
            Issue.record("another article's text is not this one's: got \(model.state)")
            return
        }
    }

    @Test func aFailureWithNothingSavedSaysWhatWentWrong() async {
        let api = FakeAPI()
        api.articleTextError = APIError(
            spokenResponse: "Sorry, I could not get the text of that article.",
            underlying: "HTTP 422")
        let model = ArticleTextModel(api: api, cache: makeCache())

        await model.load(episodeID: 1)

        guard case .failed(let message) = model.state else {
            Issue.record("expected a failure, got \(model.state)")
            return
        }
        // The sentence the player would have read out, shown instead.
        #expect(message == "Sorry, I could not get the text of that article.")
    }

    @Test func anExpiredSessionIsNotPaperedOver() async {
        // Same rule as the library: showing her the saved copy while every
        // other request 401s hides the one thing she needs to know.
        let cache = makeCache()
        cache.save(
            EpisodeText(episodeID: 7, title: "An article", text: article),
            for: .articleText(episodeID: 7))
        let api = FakeAPI()
        api.articleTextError = APIError(underlying: "HTTP 401", isAuthFailure: true)
        let model = ArticleTextModel(api: api, cache: cache)

        await model.load(episodeID: 7)

        guard case .failed = model.state else {
            Issue.record("expected a failure, got \(model.state)")
            return
        }
    }
}

@Suite("Which episodes offer their text")
struct ArticleAffordanceTests {
    @Test func aWrittenEpisodeIsAnArticle() {
        let episode = Episode(
            id: 1, title: "A post", description: nil, audioURL: nil, durationSeconds: nil,
            publishedAt: nil, link: URL(string: "https://example.com/post"), hasText: true)

        #expect(episode.isArticle)
    }

    @Test func anEpisodeWithAudioIsNot() {
        // The backend sets has_text on plenty of podcast episodes — show notes
        // are text. Offering to "read" one would open its notes, not an article.
        let episode = Episode(
            id: 1, title: "An episode", description: nil,
            audioURL: URL(string: "https://cdn.example.com/1.mp3"), durationSeconds: 600,
            publishedAt: nil, link: nil, hasText: true)

        #expect(!episode.isArticle)
    }
}

@Suite("Rendering an article")
@MainActor
struct ArticleDocumentTests {
    @Test func htmlFromTheBackendIsRenderedAsItIs() async {
        // The whole reason the reader is a web view: a post whose point is a
        // chart is not the same post with the chart taken out.
        let api = FakeAPI()
        api.articleText = "A heading\n\nProse."
        api.articleHTML = "<h2>A heading</h2><p>Prose with <em>emphasis</em>.</p>"
        let model = ArticleTextModel(api: api, cache: makeCache())

        await model.load(episodeID: 1)

        guard case .loaded(let loaded) = model.state else {
            Issue.record("expected the article, got \(model.state)")
            return
        }
        #expect(loaded.body == "<h2>A heading</h2><p>Prose with <em>emphasis</em>.</p>")
    }

    @Test func plainTextStillRendersWhenThereIsNoMarkup() async {
        // Older backends, and articles only plain text could be recovered
        // from. One renderer either way.
        let api = FakeAPI()
        api.articleText = "One.\n\nTwo."
        let model = ArticleTextModel(api: api, cache: makeCache())

        await model.load(episodeID: 1)

        guard case .loaded(let loaded) = model.state else {
            Issue.record("expected the article, got \(model.state)")
            return
        }
        #expect(loaded.body == "<p>One.</p><p>Two.</p>")
    }

    @Test func plainTextIsEscapedOnItsWayIntoTheDocument() async {
        // An article about <script> reads as one rather than becoming one.
        let api = FakeAPI()
        api.articleText = "Use <script> & </script> carefully."
        let model = ArticleTextModel(api: api, cache: makeCache())

        await model.load(episodeID: 1)

        guard case .loaded(let loaded) = model.state else {
            Issue.record("expected the article, got \(model.state)")
            return
        }
        #expect(!loaded.body.contains("<script>"))
        #expect(loaded.body.contains("&lt;script&gt;"))
        #expect(loaded.body.contains("&amp;"))
    }

    @Test func theLengthShownIsStillMeasuredFromTheSpokenText() async {
        // Not from the markup: the number on this screen is the number on the
        // scrubber, and the scrubber counts words the synthesiser will say.
        let api = FakeAPI()
        api.articleText = article
        api.articleHTML = "<p>Anything at all.</p>"
        let model = ArticleTextModel(api: api, cache: makeCache())

        await model.load(episodeID: 1)

        guard case .loaded(let loaded) = model.state else {
            Issue.record("expected the article, got \(model.state)")
            return
        }
        #expect(loaded.spokenDuration == ArticleScript(text: article).duration)
    }

    @Test func theMarkupIsSavedWithTheText() async {
        let cache = makeCache()
        let api = FakeAPI()
        api.articleText = "A heading\n\nProse."
        api.articleHTML = "<h2>A heading</h2><p>Prose.</p>"
        let model = ArticleTextModel(api: api, cache: cache)

        await model.load(episodeID: 7)
        let offline = ArticleTextModel(api: FailingAPI(), cache: cache)
        await offline.load(episodeID: 7)

        guard case .loaded(let loaded) = offline.state else {
            Issue.record("expected the saved copy, got \(offline.state)")
            return
        }
        #expect(loaded.body == "<h2>A heading</h2><p>Prose.</p>")
    }

    @Test func aCachedPayloadFromBeforeMarkupExistedStillDecodes() {
        // What the offline cache holds on a phone updated from the version
        // that shipped without HTML.
        let json = Data(#"{"episode_id":7,"title":"An article","text":"One.\n\nTwo."}"#.utf8)

        let decoded = try? JSONDecoder().decode(EpisodeText.self, from: json)

        #expect(decoded?.html == nil)
        #expect(decoded?.text == "One.\n\nTwo.")
    }

    @Test func theDocumentCarriesTheReadersTextSize() {
        // The web view's own default is a fixed sixteen pixels and ignores the
        // text size set on the phone — the one setting someone losing their
        // sight has almost certainly already turned up.
        let page = ArticleDocument.page(body: "<p>Hello</p>", pointSize: 34)

        #expect(page.contains("34.0px"))
        #expect(page.contains("<p>Hello</p>"))
        // Both appearances, since the page paints no background of its own.
        #expect(page.contains("prefers-color-scheme: dark"))
    }
}

/// Fails every request, for the offline paths.
private final class FailingAPI: HearfulAPIProtocol, @unchecked Sendable {
    func command(
        transcript: String, nowPlayingEpisodeID: Int?, turns: [ConversationTurn],
        traceparent: String?
    ) async throws -> CommandResponse
    {
        throw APIError(underlying: "offline")
    }
    func episode(id: Int) async throws -> Episode { throw APIError(underlying: "offline") }
    func articleText(episodeID: Int) async throws -> EpisodeText {
        throw APIError(underlying: "offline")
    }
    func recentEpisodes(limit: Int) async throws -> [Episode] { throw APIError(underlying: "offline") }
    func shows() async throws -> [Show] { throw APIError(underlying: "offline") }
    func episodes(showID: Int, query: String?) async throws -> [Episode] {
        throw APIError(underlying: "offline")
    }
    func searchPodcasts(query: String) async throws -> [PodcastResult] { [] }
    func previewFeed(url: URL) async throws -> FeedPreview { throw APIError(underlying: "offline") }
    func subscribe(feedURL: URL) async throws -> Show { throw APIError(underlying: "offline") }
    func unsubscribe(showID: Int) async throws {}
    func login(appleIdentityToken: String, authorizationCode: String?) async throws -> AuthResponse {
        throw APIError(underlying: "offline")
    }
    func logout() async throws {}
    func me() async throws -> UserInfo { throw APIError(underlying: "offline") }
    func deleteAccount() async throws {}
    func reportPosition(episodeID: Int, seconds: Double, completed: Bool) async throws {}
    func setEpisodeState(episodeID: Int, played: Bool?, dismissed: Bool?) async throws {}
    func reportVoiceAttempt(_ event: [String: any Sendable], traceparent: String?) async throws {}
    func reportDiagnostic(_ event: [String: any Sendable]) async throws {}
}
