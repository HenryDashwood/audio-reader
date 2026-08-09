import Foundation
import Testing

@testable import Hearful

@Suite("Article script")
struct ArticleScriptTests {
    @Test func paragraphsBecomeChunksOnAContiguousTimeline() {
        let script = ArticleScript(text: "One two three.\n\nFour five six seven.")

        #expect(script.chunks.count == 2)
        #expect(script.chunks[0].start == 0)
        #expect(script.chunks[1].start == script.chunks[0].end)
        #expect(script.duration == script.chunks[1].end)
    }

    @Test func longerParagraphsTakeLonger() {
        let short = ArticleScript(text: "A few words here.")
        let long = ArticleScript(
            text: String(repeating: "Many more words are in this paragraph. ", count: 20))

        #expect(long.duration > short.duration)
    }

    @Test func longParagraphsAreSplitIntoSentencePieces() {
        let sentence = "This sentence is repeated until the paragraph gets far too long to speak. "
        let script = ArticleScript(text: String(repeating: sentence, count: 10))

        #expect(script.chunks.count > 1)
        #expect(script.chunks.allSatisfy { $0.text.count <= 400 })
        // Splitting must never lose words.
        let words = script.chunks.flatMap { $0.text.split(separator: " ") }.count
        #expect(words == 10 * sentence.split(separator: " ").count)
    }

    @Test func indexMapsTimesBackToChunks() {
        let script = ArticleScript(text: "One two three.\n\nFour five six.\n\nSeven eight nine.")

        #expect(script.index(at: 0) == 0)
        #expect(script.index(at: script.chunks[1].start + 0.1) == 1)
        // Beyond the end clamps to the last chunk rather than failing.
        #expect(script.index(at: script.duration + 100) == script.chunks.count - 1)
    }

    @Test func blankAndWhitespaceParagraphsAreDropped() {
        let script = ArticleScript(text: "Real words.\n\n   \n\n\n\nMore words.")
        #expect(script.chunks.count == 2)
    }

    @Test func emptyTextMakesAnEmptyScript() {
        #expect(ArticleScript(text: "").isEmpty)
        #expect(ArticleScript(text: "  \n\n ").isEmpty)
    }

    @Test func timelineIsDeterministic() {
        // Saved positions only mean something if the same text always lays
        // out on the same timeline.
        let text = "Alpha beta gamma.\n\nDelta epsilon zeta eta theta."
        #expect(ArticleScript(text: text).chunks == ArticleScript(text: text).chunks)
    }
}

@Suite("Speaking rate curve")
@MainActor
struct UtteranceRateTests {
    @Test func normalSpeedIsTheSynthesiserDefault() {
        #expect(ArticlePlayer.utteranceRate(for: 1.0) == 0.5)
    }

    @Test func fasterMultipliersClimbTheQuarterSlope() {
        // The synthesiser's 0–1 scale reaches ~4× at the top; the curve must
        // never send a mild speed-up to the garbled ceiling.
        #expect(ArticlePlayer.utteranceRate(for: 1.5) == 0.625)
        #expect(ArticlePlayer.utteranceRate(for: 2.0) == 0.75)
        #expect(ArticlePlayer.utteranceRate(for: 3.0) <= 0.95)
    }

    @Test func slowerMultipliersStayGentle() {
        let slow = ArticlePlayer.utteranceRate(for: 0.75)
        #expect(slow < 0.5 && slow >= 0.3)
    }

    @Test func curveIsMonotonic() {
        let rates = stride(from: Float(0.5), through: 3.0, by: 0.25)
            .map { ArticlePlayer.utteranceRate(for: $0) }
        #expect(rates == rates.sorted())
    }
}

@Suite("Pasted feed URL detection")
struct PastedFeedURLTests {
    @Test func fullFeedURLsAreAccepted() {
        #expect(
            pastedFeedURL("https://example.com/feed.xml")?.absoluteString
                == "https://example.com/feed.xml")
    }

    @Test func bareDomainsGetHTTPS() {
        #expect(pastedFeedURL("astralcodexten.com")?.absoluteString == "https://astralcodexten.com")
    }

    @Test func showNamesAreNotURLs() {
        #expect(pastedFeedURL("the rest is history") == nil)
        #expect(pastedFeedURL("History Hour.") == nil)
        #expect(pastedFeedURL("podcasts") == nil)
        #expect(pastedFeedURL("") == nil)
    }
}
