import Foundation
import Testing
import WebKit

@MainActor
private final class CapturePageLoader: NSObject, WKNavigationDelegate {
    var continuation: CheckedContinuation<Void, Never>?

    func load(_ html: String, in view: WKWebView) async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            view.navigationDelegate = self
            view.loadHTMLString(html, baseURL: URL(string: "https://example.com/current"))
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

    private func capture(body: String, head: String = "", title: String = "City gardens provide shade") async throws -> [String: String] {
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        let loader = CapturePageLoader()
        await loader.load("<html><head><title>\(title)</title>\(head)</head><body>\(body)</body></html>", in: view)
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

    @Test func largePageChromeDoesNotDiscardASmallArticle() async throws {
        let result = try await capture(body:
            "<nav>\(String(repeating: "Navigation ", count: 60000))</nav>"
                + "<article><h1>City gardens provide shade</h1>\(paragraphs("Gardens"))</article>")
        #expect(result["contentFormat"] == "article")
        #expect(result["html"]?.contains("Gardens paragraph 0") == true)
    }
}
