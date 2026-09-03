import Testing

@testable import Hearful

struct ScreenshotRouteTests {
    @Test func namesTheThreeTabs() {
        #expect(ScreenshotRoute.parse("following") == .following)
        #expect(ScreenshotRoute.parse("Latest") == .latest)
        #expect(ScreenshotRoute.parse(" settings ") == .settings)
    }

    @Test func addressesAShowOrArticleByID() {
        #expect(ScreenshotRoute.parse("show:4") == .show(id: 4))
        #expect(ScreenshotRoute.parse("article:12") == .article(episodeID: 12))
    }

    @Test func refusesAnythingElse() {
        #expect(ScreenshotRoute.parse(nil) == nil)
        #expect(ScreenshotRoute.parse("") == nil)
        #expect(ScreenshotRoute.parse("show") == nil)
        #expect(ScreenshotRoute.parse("show:0") == nil)
        #expect(ScreenshotRoute.parse("show:four") == nil)
        #expect(ScreenshotRoute.parse("player:1") == nil)
    }
}
