import Foundation
import Testing
import WebKit

@testable import Hearful

private func makeCache() -> OfflineCache {
    let directory = URL.temporaryDirectory.appending(path: "article-tests-\(UUID().uuidString)")
    return OfflineCache(directory: directory)
}

private let article = """
    The first paragraph, which is short.

    The second paragraph, which is also short.
    """

@MainActor
private final class ArticleWebViewLoadWaiter: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Never>?

    func load(_ document: String, in webView: WKWebView) async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            webView.navigationDelegate = self
            webView.loadHTMLString(document, baseURL: nil)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finish()
    }

    func webView(
        _ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error
    ) {
        finish()
    }

    private func finish() {
        continuation?.resume()
        continuation = nil
    }
}

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

    @Test func aSuccessfulLoadReturnsTheCountForItsRow() async {
        let api = FakeAPI()
        api.articleText = "One, two... three! -- four?"
        api.articleWordCount = 4
        let model = ArticleTextModel(api: api, cache: makeCache())

        let wordCount = await model.load(episodeID: 7)

        #expect(wordCount == 4)
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

    @Test func aSavedCopyCanRestoreTheCountWhileOffline() async {
        let cache = makeCache()
        cache.save(
            EpisodeText(
                episodeID: 7, title: "An article", text: article,
                wordCount: 13),
            for: .articleText(episodeID: 7))
        let api = FakeAPI()
        api.articleTextError = APIError(underlying: "offline")
        let model = ArticleTextModel(api: api, cache: cache)

        let wordCount = await model.load(episodeID: 7)

        #expect(wordCount == 13)
    }

    @Test func aTeaserDoesNotBecomeTheArticleLength() async {
        let api = FakeAPI()
        api.articleText = "A short introduction. Continue reading"
        api.articleWordCount = nil
        let model = ArticleTextModel(api: api, cache: makeCache())

        let wordCount = await model.load(episodeID: 7)

        #expect(wordCount == nil)
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

    @Test func savedArticleCanBeReadWithoutTheInternet() async {
        let cache = makeCache()
        cache.save(
            EpisodeText(episodeID: 7, title: "An article", text: article),
            for: .articleText(episodeID: 7))
        let synthesizer = SilentSynthesizer()
        let player = ArticlePlayer(
            api: FailingAPI(), cache: cache, synthesizer: synthesizer)
        let episode = Episode(
            id: 7, title: "An article", description: nil, audioURL: nil,
            durationSeconds: nil, publishedAt: nil, link: nil, imageURL: nil,
            positionSeconds: nil, completed: nil, hasText: true)

        player.play(episode)
        for _ in 0..<100 where synthesizer.lastSpoken == nil {
            try? await Task.sleep(for: .milliseconds(20))
        }

        #expect(synthesizer.lastSpoken?.contains("The first paragraph") == true)
        #expect(player.isPlaying)
    }

    @Test func aSavedFeedTeaserIsRefreshedBeforeItIsRead() async {
        let cache = makeCache()
        cache.save(
            EpisodeText(
                episodeID: 7, title: "An article",
                text: "A short introduction. Continue reading"),
            for: .articleText(episodeID: 7))
        let api = FakeAPI()
        api.articleText = String(repeating: "The recovered full article. ", count: 40)
        let synthesizer = SilentSynthesizer()
        let player = ArticlePlayer(api: api, cache: cache, synthesizer: synthesizer)
        let episode = Episode(
            id: 7, title: "An article", description: nil, audioURL: nil,
            durationSeconds: nil, publishedAt: nil,
            link: URL(string: "https://example.com/article"), imageURL: nil,
            positionSeconds: nil, completed: nil, hasText: true)

        player.play(episode)
        for _ in 0..<100 where synthesizer.lastSpoken == nil {
            try? await Task.sleep(for: .milliseconds(20))
        }

        #expect(synthesizer.lastSpoken?.contains("recovered full article") == true)
        #expect(
            cache.load(EpisodeText.self, for: .articleText(episodeID: 7))?.text
                == api.articleText)
    }

    @Test func aSavedFeedTeaserRemainsAnOfflineFallback() async {
        let cache = makeCache()
        let teaser = "A short introduction. Continue reading"
        cache.save(
            EpisodeText(episodeID: 7, title: "An article", text: teaser),
            for: .articleText(episodeID: 7))
        let synthesizer = SilentSynthesizer()
        let player = ArticlePlayer(
            api: FailingAPI(), cache: cache, synthesizer: synthesizer)
        let episode = Episode(
            id: 7, title: "An article", description: nil, audioURL: nil,
            durationSeconds: nil, publishedAt: nil,
            link: URL(string: "https://example.com/article"), imageURL: nil,
            positionSeconds: nil, completed: nil, hasText: true)

        player.play(episode)
        for _ in 0..<100 where synthesizer.lastSpoken == nil {
            try? await Task.sleep(for: .milliseconds(20))
        }

        #expect(synthesizer.lastSpoken == teaser)
        #expect(player.isPlaying)
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
        #expect(decoded?.wordCount == nil)
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

    @Test func theMarkerBridgeIsIsolatedAndTargetsOnlyTheArticleBody() {
        let body = ArticleDocument.articleBody("<p>Spoken words.</p>")

        #expect(ArticleReadingMarkerScript.source.contains("hearful-article-body"))
        #expect(ArticleReadingMarkerScript.source.contains("rectForRange"))
        #expect(body == "<main id=\"hearful-article-body\"><p>Spoken words.</p></main>")
    }

    @Test func theNativeMarkerIncludesTheWebViewsAdjustedTopInset() {
        // The web view extends behind the floating navigation bar. WebKit's
        // DOM rectangle does not include that bar's adjusted scroll inset,
        // while a UIView added to the scroll view must include it explicitly.
        let contentOffset = CGPoint(x: 0, y: -104)
        let inset = UIEdgeInsets(top: 104, left: 8, bottom: 82, right: 0)
        let frame = ArticleReadingMarkerLayout.frame(
            domTop: 180,
            height: 20,
            contentOffset: contentOffset,
            adjustedContentInset: inset)

        #expect(ArticleReadingMarkerLayout.visibleTop(
            domTop: 180,
            adjustedContentInset: inset) == 284)
        #expect(frame.minY - contentOffset.y == 284)
        #expect(frame.minX - contentOffset.x == 14)
    }

    @Test func scrollingStaysDetachedUntilTheReaderExplicitlyFollowsAgain() {
        var state = ArticleReadingFollowState()

        state.userDidScroll(whileReading: true)
        #expect(!state.isFollowing)

        // Spoken-word updates and elapsed time do not mutate this state.
        #expect(!state.isFollowing)

        state.resume()
        #expect(state.isFollowing)
    }

    @Test func scrollingWithoutAnActiveReadingDoesNotOfferFollowing() {
        var state = ArticleReadingFollowState()

        state.userDidScroll(whileReading: false)

        #expect(state.isFollowing)
    }

    @Test func theFollowControlExplainsItsActionWithoutItsIcon() {
        let button = ArticleReadingFollowButton()

        #expect(button.configuration?.title == "Follow reading")
        #expect(button.intrinsicContentSize.height >= 44)
        #expect(button.accessibilityLabel == "Follow the reading position")
        #expect(button.accessibilityHint?.contains("current word") == true)
    }

    @Test func theFollowControlClearsTheMiniPlayerOnlyWhileItIsVisible() {
        let abovePlayer = ArticleReadingFollowLayout.bottomConstraintConstant(
            chromeHidden: false,
            miniPlayerHeight: 52,
            gap: 10)
        let withoutPlayer = ArticleReadingFollowLayout.bottomConstraintConstant(
            chromeHidden: true,
            miniPlayerHeight: 52,
            gap: 10)

        #expect(abovePlayer == -86)
        #expect(withoutPlayer == -12)
    }

    @Test func thePageNeverScrollsSidewaysHoweverWideItsContent() async throws {
        // WebKit will neither wrap nor scroll MathML, and a sentence wrongly
        // taken for a formula once pushed a whole article sideways under the
        // thumb. The page must hold its width whatever the article holds.
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let webView = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 700),
            configuration: configuration)
        let formula = String(repeating: "<mi>word</mi><mo>+</mo>", count: 80)
        let document = ArticleDocument.page(
            body: ArticleDocument.articleBody(
                "<p>Before <math>\(formula)</math> after.</p>"
                    + "<div style=\"width: 3000px\">wide</div>"),
            pointSize: 17)

        let waiter = ArticleWebViewLoadWaiter()
        await waiter.load(document, in: webView)
        let result = try await webView.callAsyncJavaScript(
            """
            return {
              scrollWidth: document.documentElement.scrollWidth,
              clientWidth: document.documentElement.clientWidth,
              mathWidth: document.querySelector("math").getBoundingClientRect().width
            };
            """,
            arguments: [:],
            in: nil,
            contentWorld: ArticleReadingMarkerScript.world)
        let widths = result as? [String: Any]
        let scrollWidth = (widths?["scrollWidth"] as? NSNumber)?.doubleValue
        let clientWidth = (widths?["clientWidth"] as? NSNumber)?.doubleValue
        let mathWidth = (widths?["mathWidth"] as? NSNumber)?.doubleValue

        // The formula really is wider than the phone, so the guard did work.
        #expect(mathWidth ?? 0 > 390)
        #expect(scrollWidth != nil)
        #expect(scrollWidth ?? .infinity <= clientWidth ?? 0)
    }

    @Test func theIsolatedBridgeFindsAWordWhilePageJavaScriptIsDisabled() async throws {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let webView = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 700),
            configuration: configuration)
        let speech = "First moving marker."
        let document = ArticleDocument.page(
            // Raw URLs are dropped from speech and formulae are rendered into
            // a different textual shape. Neither may shift all later words.
            body: ArticleDocument.articleBody(
                "<p>First https://example.com/path <math><mi>x</mi></math> "
                    + "<em>moving</em> marker.</p>"),
            pointSize: 17)

        let waiter = ArticleWebViewLoadWaiter()
        await waiter.load(document, in: webView)
        try await ArticleReadingMarkerScript.install(in: webView)
        let mapped = try await webView.callAsyncJavaScript(
            "return globalThis.hearfulArticleMarker.configure(text);",
            arguments: ["text": speech],
            in: nil,
            contentWorld: ArticleReadingMarkerScript.world)
        let word = (speech as NSString).range(of: "moving")
        let result = try await webView.callAsyncJavaScript(
            "return globalThis.hearfulArticleMarker.rectForRange(location, length);",
            arguments: ["location": word.location, "length": word.length],
            in: nil,
            contentWorld: ArticleReadingMarkerScript.world)
        let rect = result as? [String: Any]

        #expect((mapped as? NSNumber)?.intValue == 3)
        #expect((rect?["top"] as? NSNumber)?.doubleValue != nil)
        #expect((rect?["height"] as? NSNumber)?.doubleValue ?? 0 > 0)

        // Languages without spaces still need the marker to move word by
        // word, rather than treating a whole paragraph as one enormous token.
        let japanese = "今日は世界です"
        _ = try await webView.callAsyncJavaScript(
            "document.getElementById('hearful-article-body').innerHTML = '<p>今日は世界です</p>';",
            arguments: [:],
            in: nil,
            contentWorld: ArticleReadingMarkerScript.world)
        _ = try await webView.callAsyncJavaScript(
            "return globalThis.hearfulArticleMarker.configure(text);",
            arguments: ["text": japanese],
            in: nil,
            contentWorld: ArticleReadingMarkerScript.world)
        let japaneseWord = (japanese as NSString).range(of: "世界")
        let japaneseResult = try await webView.callAsyncJavaScript(
            "return globalThis.hearfulArticleMarker.rectForRange(location, length);",
            arguments: ["location": japaneseWord.location, "length": japaneseWord.length],
            in: nil,
            contentWorld: ArticleReadingMarkerScript.world)
        let japaneseRect = japaneseResult as? [String: Any]

        #expect((japaneseRect?["top"] as? NSNumber) != nil)
    }
}

@Suite("An article's heading")
struct ArticleHeaderTests {
    private let published = Date(timeIntervalSince1970: 1_785_801_600)  // 4 August 2026
    /// However this phone's region writes it — the test is about what is in
    /// the line and in which order, not about which country reads it.
    private var date: String { published.formatted(.dateTime.day().month(.wide).year()) }

    @Test func theBylineShowsPublicationAuthorAndDateInOrder() {
        let header = ArticleDocument.header(
            title: "The Beauty Of Settled Science", feedTitle: "Astral Codex Ten",
            feedURL: URL(string: "https://www.astralcodexten.com/feed"),
            author: "Ada Whitfield",
            publishedAt: published)

        #expect(header.contains("<h1>The Beauty Of Settled Science</h1>"))
        #expect(
            header.contains(
                "<p class=\"meta\"><a href=\"hearful://feed\">Astral Codex Ten</a> · Ada Whitfield · \(date)</p>"))
    }

    @Test func howLongItTakesToHearIsNotInIt() {
        // It was, and it is a fact about the app rather than about the piece.
        // The scrubber says it the moment she starts listening.
        let header = ArticleDocument.header(
            title: "A post", feedTitle: "Ada's Blog", feedURL: nil,
            author: nil,
            publishedAt: published)

        #expect(!header.contains("to listen"))
        #expect(!header.contains(" min"))
    }

    @Test func anEpisodeWithoutFeedMetadataShowsItsDateAlone() {
        // Cached episodes from an older backend may not identify their feed.
        let header = ArticleDocument.header(
            title: "A post", feedTitle: nil, feedURL: nil, author: nil,
            publishedAt: published)

        #expect(header.contains("<p class=\"meta\">\(date)</p>"))
    }

    @Test func aBlankFeedTitleIsNotADanglingSeparator() {
        let header = ArticleDocument.header(
            title: "A post", feedTitle: "   ",
            feedURL: URL(string: "https://example.com/feed"), author: nil,
            publishedAt: published)

        #expect(!header.contains("·"))
        #expect(header.contains("<p class=\"meta\">\(date)</p>"))
    }

    @Test func withNeitherThereIsNoBylineAtAll() {
        let header = ArticleDocument.header(
            title: "A post", feedTitle: nil, feedURL: nil, author: nil, publishedAt: nil)

        #expect(header == "<h1>A post</h1>")
    }

    @Test func aFeedNameIsEscapedOnItsWayIn() {
        let header = ArticleDocument.header(
            title: "A post", feedTitle: "Ben & Jerry <b>", feedURL: nil,
            author: nil,
            publishedAt: nil)

        #expect(header.contains("Ben &amp; Jerry &lt;b&gt;"))
    }

    @Test func anAuthorWithoutOtherMetadataStillGetsAByline() {
        let header = ArticleDocument.header(
            title: "A post", feedTitle: nil, feedURL: nil, author: "Mara Bell",
            publishedAt: nil)

        #expect(header.contains("<p class=\"meta\">Mara Bell</p>"))
    }

    @Test func aBlankOrPublicationLevelAuthorIsNotRepeated() {
        let blank = ArticleDocument.header(
            title: "A post", feedTitle: "The Dispatch", feedURL: nil, author: "   ",
            publishedAt: published)
        let duplicate = ArticleDocument.header(
            title: "A post", feedTitle: "The Dispatch", feedURL: nil,
            author: "the dispatch", publishedAt: published)

        #expect(blank.contains("<p class=\"meta\">The Dispatch · \(date)</p>"))
        #expect(duplicate.contains("<p class=\"meta\">The Dispatch · \(date)</p>"))
    }

    @Test func anAuthorNameIsEscapedOnItsWayIn() {
        let header = ArticleDocument.header(
            title: "A post", feedTitle: nil, feedURL: nil,
            author: "Johnson & Johnson <News>", publishedAt: nil)

        #expect(header.contains("Johnson &amp; Johnson &lt;News&gt;"))
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
    func reportPosition(
        episodeID: Int, seconds: Double, completed: Bool, durationSeconds: Int?
    ) async throws {}
    func setEpisodeState(episodeID: Int, played: Bool?, dismissed: Bool?) async throws {}
    func reportVoiceAttempt(_ event: [String: any Sendable], traceparent: String?) async throws {}
    func reportDiagnostic(_ event: [String: any Sendable]) async throws {}
}
