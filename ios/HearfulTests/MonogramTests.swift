import Testing

@testable import Hearful

@Suite("A show's monogram")
struct MonogramTests {
    @Test func takesTheFirstTwoInitials() {
        #expect(Monogram.initials(of: "Simon Willison's Weblog") == "SW")
        #expect(Monogram.initials(of: "Astral Codex Ten") == "AC")
        #expect(Monogram.initials(of: "Baldwin") == "B")
    }

    @Test func skipsALeadingArticleWhenSomethingFollows() {
        #expect(Monogram.initials(of: "The Diff") == "D")
        #expect(Monogram.initials(of: "The Rest Is History") == "RI")
        #expect(Monogram.initials(of: "A") == "A")
    }

    @Test func ignoresPunctuationAndSurvivesAnEmptyTitle() {
        #expect(Monogram.initials(of: "Razib Khan's Unsupervised Learning") == "RK")
        #expect(Monogram.initials(of: "Money Stuff — Matt Levine") == "MS")
        #expect(Monogram.initials(of: "80,000 Hours Podcast") == "8H")
        #expect(Monogram.initials(of: "") == "")
    }

    @Test func colourIsStableAndVaries() {
        let acx = Monogram.hue(for: "Astral Codex Ten")
        #expect(acx == Monogram.hue(for: "Astral Codex Ten"))
        #expect(acx == Monogram.hue(for: "astral codex ten"))
        #expect((0..<1).contains(acx))
        let hues = Set(["Baldwin", "Slow Boring", "Money Stuff", "The Diff", "Razib Khan"].map(Monogram.hue(for:)))
        #expect(hues.count >= 4)
    }
}
