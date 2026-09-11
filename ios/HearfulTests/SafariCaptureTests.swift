import Foundation
import Testing
import WebKit

@MainActor
private final class CapturePageLoader: NSObject, WKNavigationDelegate {
    var continuation: CheckedContinuation<Void, Never>?

    func load(_ html: String, in view: WKWebView, url: URL) async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            view.navigationDelegate = self
            view.loadHTMLString(html, baseURL: url)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        continuation?.resume()
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        continuation?.resume()
        continuation = nil
    }
}

@Suite("Safari article capture")
@MainActor
struct SafariCaptureTests {
    private func paragraphs(_ subject: String, count: Int = 8) -> String {
        (0..<count).map {
            "<p>\(subject) paragraph \($0). This story explains the evidence in detail, with examples and observations that help readers understand the subject and its significance.</p>"
        }.joined()
    }

    private func capture(body: String, head: String = "", title: String = "City gardens provide shade", url: String = "https://example.com/current") async throws -> [String: String] {
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        let loader = CapturePageLoader()
        await loader.load("<html><head><title>\(title)</title>\(head)</head><body>\(body)</body></html>", in: view, url: try #require(URL(string: url)))
        let plugins = try #require(Bundle.main.builtInPlugInsURL)
        let script = try String(contentsOf: plugins.appending(path: "HearfulShare.appex/CapturePage.js"), encoding: .utf8)
        let result = try await view.callAsyncJavaScript(
            script + "\nreturn await new Promise(resolve => ExtensionPreprocessingJS.run({completionFunction: resolve}));",
            arguments: [:], in: nil, contentWorld: .page)
        return try #require(result as? [String: String])
    }

    @Test(arguments: ["class='hidden-story'", "aria-hidden='true'", "hidden", "style='visibility:hidden'", "style='content-visibility:hidden'"])
    func aHiddenLongerArticleCannotDisplaceTheVisibleStory(hidden: String) async throws {
        let result = try await capture(
            body: "<article><h1>City gardens provide shade</h1>\(paragraphs("Gardens"))</article>"
                + "<section \(hidden)><article><h1>Satellite engineering</h1>\(paragraphs("Satellites", count: 30))</article></section>",
            head: "<style>.hidden-story { display: none; }</style>")
        #expect(result["contentFormat"] == "article")
        #expect(result["html"]?.contains("Gardens paragraph 0") == true)
        #expect(result["html"]?.contains("Satellites") == false)
        #expect(result["preview"]?.hasPrefix("Gardens paragraph 0") == true)
    }

    @Test func capturedArticlesKeepVideoPlayersForBackendSanitisation() async throws {
        let result = try await capture(
            body: "<article><h1>City gardens provide shade</h1>\(paragraphs("Gardens"))"
                + "<iframe loading='lazy' src='https://www.youtube-nocookie.com/embed/Wp7YrZ1H05g' title='A performance'></iframe>"
                + "<iframe src='https://tracker.example.com'></iframe><p>After the video.</p></article>",
            head: "<meta http-equiv='Content-Security-Policy' content=\"frame-src 'none'\">")
        #expect(result["html"]?.contains("https://www.youtube-nocookie.com/embed/Wp7YrZ1H05g") == true)
        #expect(result["html"]?.contains("tracker.example.com") == false)
        #expect(result["html"]?.contains("After the video.") == true)
    }

    @Test func selectsTheMatchingStoryAndKeepsItsOffscreenParagraphs() async throws {
        let result = try await capture(body:
            "<article><h1>Satellite engineering is changing</h1>\(paragraphs("Satellites", count: 30))</article>"
                + "<article><h1>City gardens provide shade</h1>\(paragraphs("Gardens"))<p><a href='/more'>More evidence</a></p></article>")
        #expect(result["html"]?.contains("Satellites") == false)
        #expect(result["html"]?.contains("Gardens paragraph 7") == true)
        #expect(result["html"]?.contains("https://example.com/more") == true)
    }

    @Test func competingStoriesWithoutAMatchingTitleSaveOnlyTheLink() async throws {
        let result = try await capture(body:
            "<article><h1>Satellite engineering</h1>\(paragraphs("Satellites"))</article>"
                + "<article><h1>Growing vegetables</h1>\(paragraphs("Gardens"))</article>")
        #expect(result["html"] == "")
        #expect(result["contentFormat"] == nil)
    }

    @Test func splitPublisherArticlesKeepTheirVisibleHeadline() async throws {
        let result = try await capture(
            body: "<article elid='123'><h1>The visible headline</h1></article>"
                + "<article elid='123'>\(paragraphs("Gardens"))</article>"
                + "<article elid='456'><h2>A related story</h2><p>A teaser.</p></article>",
            title: "A different search engine headline")
        #expect(result["title"] == "The visible headline")
        #expect(result["html"]?.contains("Gardens paragraph 0") == true)
        #expect(result["html"]?.contains("A related story") == false)
    }

    @Test func staleCanonicalIdentityFallsBackToTheCurrentLink() async throws {
        let result = try await capture(
            body: "<article><h1>City gardens provide shade</h1>\(paragraphs("Gardens"))</article>",
            head: "<link rel='canonical' href='https://example.com/previous'>")
        #expect(result["html"] == "")
        #expect(result["url"] == "https://example.com/current")
    }

    @Test(arguments: ["archive.is", "archive.today", "archive.ph", "archive.li", "archive.vn", "archive.fo", "archive.md"])
    func archiveShortLinkCapturesItsDeclaredSnapshot(host: String) async throws {
        let url = "https://\(host)/1Ip09"
        let snapshot = "https://\(host)/2026.09.10-074027/https://example.com/story"
        // Archive markup uses a separate asset base and flattened div paragraphs.
        let prose = paragraphs("Gardens").replacingOccurrences(of: "<p>", with: "<div>")
            .replacingOccurrences(of: "</p>", with: "</div>")
        let result = try await capture(
            body: "<article><h1>City gardens provide shade</h1>\(prose)</article>",
            head: "<base href='https://assets.\(host)/'><link rel='canonical' href='\(snapshot)'>"
                + "<meta property='og:url' content='\(url)'>", url: url)
        #expect(result["contentFormat"] == "article")
        #expect(result["url"] == url)
        #expect(result["title"] == "City gardens provide shade")
        #expect(result["html"]?.contains("Gardens paragraph 7") == true)
        #expect(result["html"]?.contains("href=\"\(url)\"") == true)
        #expect(result["preview"]?.isEmpty == false)
    }

    @Test(arguments: [
        "", // No evidence that the long and short URLs describe the same snapshot.
        "<meta property='og:url' content='https://archive.is/other'>",
        "<meta property='og:url' content='https://archive.is/1Ip09'><meta property='og:url' content='https://archive.is/other'>",
    ])
    func archiveMissingOrStaleShortIdentityKeepsOnlyTheLink(metadata: String) async throws {
        let result = try await capture(
            body: "<article><h1>City gardens provide shade</h1>\(paragraphs("Gardens"))</article>",
            head: "<link rel='canonical' href='https://archive.is/2026.09.10-074027/https://example.com/story'>\(metadata)",
            url: "https://archive.is/1Ip09")
        #expect(result["html"] == "")
    }

    @Test(arguments: [
        ("https://example.com/1Ip09", "https://example.com/2026.09.10-074027/https://publisher.com/story"),
        ("https://archive.is.evil.example/1Ip09", "https://archive.is.evil.example/2026.09.10-074027/https://publisher.com/story"),
        ("https://archive.is/1Ip09", "https://publisher.com/story"),
        ("https://archive.is/1Ip09", "https://archive.is/other"),
        ("https://archive.is/1Ip09", "https://archive.ph/2026.09.10-074027/https://publisher.com/story"),
        ("https://archive.is/search", "https://archive.is/2026.09.10-074027/https://publisher.com/story"),
    ])
    func matchingOpenGraphURLDoesNotGenerallyOverrideCanonical(url: String, canonical: String) async throws {
        let result = try await capture(
            body: "<article><h1>City gardens provide shade</h1>\(paragraphs("Gardens"))</article>",
            head: "<link rel='canonical' href='\(canonical)'><meta property='og:url' content='\(url)'>", url: url)
        #expect(result["html"] == "")
    }

    @Test func largePageChromeDoesNotDiscardASmallArticle() async throws {
        let result = try await capture(body:
            "<nav>\(String(repeating: "Navigation ", count: 60000))</nav>"
                + "<article><h1>City gardens provide shade</h1>\(paragraphs("Gardens"))</article>")
        #expect(result["contentFormat"] == "article")
        #expect(result["html"]?.contains("Gardens paragraph 0") == true)
    }
}
