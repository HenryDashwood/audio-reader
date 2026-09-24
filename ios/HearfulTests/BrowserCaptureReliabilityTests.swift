import Foundation
import Testing
import WebKit

@MainActor
private final class ReliabilityPageLoader: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Never>?

    func load(_ html: String, into view: WKWebView, url: URL) async {
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

@Suite("Browser capture reliability", .serialized)
@MainActor
struct BrowserCaptureReliabilityTests {
    private func resource(_ name: String, extension suffix: String = "html") throws -> String {
        let bundle = Bundle(for: ReliabilityPageLoader.self)
        let url = try #require(bundle.url(forResource: name, withExtension: suffix))
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func script() throws -> String {
        let plugins = try #require(Bundle.main.builtInPlugInsURL)
        return try String(contentsOf: plugins.appending(path: "HearfulShare.appex/CapturePage.js"), encoding: .utf8)
    }

    private func capture(_ html: String, url: String, setup: String = "") async throws -> [String: String] {
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        let loader = ReliabilityPageLoader()
        await loader.load(html, into: view, url: try #require(URL(string: url)))
        let result = try await view.callAsyncJavaScript(
            script() + "\n" + setup + "\nreturn await new Promise(resolve => ExtensionPreprocessingJS.run({completionFunction: resolve}));",
            arguments: [:], in: nil, contentWorld: .page)
        return try #require(result as? [String: String])
    }

    @Test func splitPublisherRetainsBothSectionsImagesAndCaptions() async throws {
        let result = try await capture(resource("canary-split"), url: "https://www.canarymedia.com/articles/geothermal/dig-energy-novel-geothermal-drilling-tech")
        let html = try #require(result["html"])
        #expect(result["contentFormat"] == "article")
        #expect(result["title"] == "A better geothermal drill")
        #expect(html.components(separatedBy: "<img").count - 1 == 2)
        var previous = html.startIndex
        for section in ["Opening", "Continuation"] {
            for index in 0..<8 {
                let range = try #require(html.range(of: "\(section) paragraph \(index)"))
                #expect(range.lowerBound >= previous)
                previous = range.upperBound
            }
        }
        #expect(html.contains("https://www.canarymedia.com/first.jpg"))
        #expect(html.contains("https://www.canarymedia.com/second.jpg"))
        #expect(html.contains("First photograph caption."))
        #expect(html.contains("Second photograph caption."))
        #expect(html.contains("How the equipment works"))
        #expect(html.contains("<li>A useful list item</li>"))
        #expect(!html.contains("Unrelated"))
        #expect(!html.contains("Newsletter"))
        #expect(!html.contains("Author biography"))
    }

    @Test func shortGallerySurvivesWithoutSponsorOrFooter() async throws {
        let result = try await capture(resource("short-gallery"), url: "https://simonwillison.net/2026/Sep/12/sighting-399708714/")
        let html = try #require(result["html"])
        #expect(result["contentFormat"] == "article")
        #expect(html.components(separatedBy: "<img").count - 1 == 2)
        #expect(html.contains("waterfront walkway"))
        #expect(html.contains("whole pier to themselves"))
        #expect(!html.contains("Sponsored"))
        #expect(!html.contains("Posted yesterday"))
    }

    @Test func chartsReachBackendWithCaptionsAndDescriptions() async throws {
        let result = try await capture(resource("inline-charts"), url: "https://example.com/charts")
        let html = try #require(result["html"])
        #expect(html.components(separatedBy: "<svg").count - 1 == 4)
        #expect(html.contains("Benchmark chart 3"))
        #expect(html.contains("Caption 3"))
        #expect(html.contains("final conclusion"))
    }

    @Test func uncertainKnownLayoutSavesOnlyTheLink() async throws {
        let raw = try resource("short-gallery").replacingOccurrences(of: "class=\"beat-content\"", with: "class=\"unknown\"")
        let result = try await capture(raw, url: "https://simonwillison.net/2026/Sep/12/sighting-399708714/")
        #expect(result["html"] == "")
        #expect(result["contentFormat"] == nil)
    }

    @Test func extractionCannotSilentlyDropSubstantialArticleParagraphs() async throws {
        let raw = try resource("inline-charts")
        let result = try await capture(raw, url: "https://example.com/charts", setup: """
            var first = document.querySelector('article p').outerHTML;
            Readability.prototype.parse = function () { return {content:first, title:document.title, length:500, textContent:first}; };
            """)
        #expect(result["html"] == "")
        #expect(result["contentFormat"] == nil)
    }

    @Test func aSidebarInsideTheArticleIsNotEvidenceOfMissingBodyText() async throws {
        let raw = try resource("article-with-sidebar")
        let result = try await capture(raw, url: "https://example.com/article-with-sidebar")
        let html = try #require(result["html"])
        #expect(result["contentFormat"] == "article")
        #expect(html.contains("Opening body paragraph"))
        #expect(html.contains("Closing body paragraph"))
        #expect(!html.contains("Promoted podcast"))
        let truncated = try await capture(raw, url: "https://example.com/article-with-sidebar", setup: """
            var first = document.querySelector('.td-post-content p').outerHTML;
            Readability.prototype.parse = function () { return {content:first, title:document.title, length:500, textContent:first}; };
            """)
        #expect(truncated["html"] == "")
    }

    @Test func responsiveAndLazyImagesUseResolvedSources() async throws {
        let raw = try resource("inline-charts").replacingOccurrences(of: "</article>", with: """
            <img id="selected" src="/placeholder.jpg" srcset="/small.jpg 1x, /large.jpg 2x">
            <img src="data:image/gif;base64,AAAA" data-src="/lazy.jpg">
            <img srcset="/medium.jpg?crop=1,2 640w, /largest.jpg 1280w">
            <picture><source media="(min-width:9999px)" srcset="/wrong.jpg 2x"><source srcset="/picture.jpg 2x"><img alt="Picture"></picture>
            </article>
            """)
        let result = try await capture(raw, url: "https://example.com/charts", setup: """
            document.querySelectorAll('img').forEach(img => Object.defineProperty(img, 'currentSrc', {value:''}));
            Object.defineProperty(document.querySelector('#selected'), 'currentSrc', {value:'https://example.com/browser-selected.jpg'});
            """.replacingOccurrences(of: "{value:''}", with: "{value:'', configurable:true}"))
        let html = try #require(result["html"])
        for path in ["browser-selected.jpg", "lazy.jpg", "largest.jpg", "picture.jpg"] {
            #expect(html.contains("https://example.com/\(path)"))
        }
        #expect(!html.contains("wrong.jpg"))
        #expect(!html.contains("srcset="))
        #expect(!html.contains("placeholder.jpg"))
    }

    @Test func shortIdentifiedIllustratedArticlesWorkBeyondPublisherAdapters() async throws {
        let raw = """
            <html><head><title>Birds on a pier</title><link rel="canonical" href="https://example.com/birds"><meta property="og:type" content="article">
            <meta http-equiv="Content-Security-Policy" content="default-src 'none'"></head><body><article><h1>Birds on a pier</h1>
            <figure><img src="https://example.com/birds.jpg" alt="Birds"></figure>
            <p>The pier has become a gathering place for birds while it is closed for repairs.</p></article></body></html>
            """
        let result = try await capture(raw, url: "https://example.com/birds")
        #expect(result["contentFormat"] == "article")
        #expect(result["html"]?.contains("birds.jpg") == true)
        let uncertain = try await capture(raw.replacingOccurrences(of: "<meta property=\"og:type\" content=\"article\">", with: ""), url: "https://example.com/birds")
        #expect(uncertain["html"] == "")
    }

    @Test func socialTitlesMatchTheBackendPolicy() async throws {
        let view = WKWebView()
        let loader = ReliabilityPageLoader()
        await loader.load("<html><body></body></html>", into: view, url: URL(string: "https://example.com")!)
        let cases = try resource("social-titles", extension: "json")
        let result = try await view.callAsyncJavaScript(script() + """
            return JSON.parse(cases).map(c => ({ actual: MagpieCapture.socialTitle(c.url, c.title, c.text, c.headline), expected: c.expected }));
            """, arguments: ["cases": cases], in: nil, contentWorld: .page)
        for row in try #require(result as? [[String: String]]) {
            #expect(row["actual"] == row["expected"])
        }
    }

    @Test func socialCapturePreviewTitleDoesNotRepeatTheBody() async throws {
        let text = "A small discovery. " + String(repeating: "Detailed observations about the whole story. ", count: 40)
        let raw = "<html><head><title>Writer on X: &quot;\(text)&quot; / X</title></head><body><article><p>\(text)</p></article></body></html>"
        let result = try await capture(raw, url: "https://x.com/writer/status/123")
        #expect(result["title"] == "@writer: A small discovery.")
        #expect(result["html"]?.components(separatedBy: "Detailed observations").count == 41)
        #expect(result["preview"]?.hasPrefix("A small discovery.") == true)
    }

    @Test func sanitizedChartImagesRenderAtNarrowReaderWidths() async throws {
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        let loader = ReliabilityPageLoader()
        await loader.load(try resource("static-chart"), into: view, url: URL(string: "https://example.com")!)
        let result = try await view.callAsyncJavaScript("""
            const image = document.querySelector('img');
            await image.decode();
            const canvas = document.createElement('canvas');
            canvas.width = 640; canvas.height = 420;
            const context = canvas.getContext('2d');
            context.drawImage(image, 0, 0, 640, 420);
            const circle = context.getImageData(150, 150, 1, 1).data;
            const background = context.getImageData(600, 200, 1, 1).data;
            return [image.naturalWidth, image.naturalHeight, Math.round(image.getBoundingClientRect().width),
                document.documentElement.scrollWidth, ...circle, ...background];
            """, arguments: [:], in: nil, contentWorld: .page)
        let metrics = try #require(result as? [Int])
        #expect(metrics[0] > 0)
        #expect(metrics[1] > 0)
        #expect(abs(Double(metrics[0]) / Double(metrics[1]) - 640.0 / 420.0) < 0.02)
        #expect(metrics[2] <= 320)
        #expect(metrics[3] <= 320)
        #expect(Array(metrics[4..<8]) == [255, 85, 0, 255])
        #expect(Array(metrics[8..<12]) == [255, 255, 255, 255])
    }
}
