import Testing

@testable import Hearful

@Suite("Article chrome scrolling")
struct ArticleChromeScrollTrackerTests {
    @Test func downwardReadingGestureHidesOnlyOnce() {
        var tracker = ArticleChromeScrollTracker()
        tracker.began(translationY: 0, hidden: false)

        #expect(tracker.changed(translationY: -10, contentOffsetY: 100) == true)
        #expect(tracker.changed(translationY: -20, contentOffsetY: 110) == nil)
        #expect(tracker.changed(translationY: -30, contentOffsetY: 120) == nil)
    }

    @Test func upwardGestureShowsOnlyOnce() {
        var tracker = ArticleChromeScrollTracker()
        tracker.began(translationY: 0, hidden: true)

        #expect(tracker.changed(translationY: 10, contentOffsetY: 100) == false)
        #expect(tracker.changed(translationY: 20, contentOffsetY: 90) == nil)
    }

    @Test func reboundAfterGestureEndsDoesNotReplayAnimation() {
        var tracker = ArticleChromeScrollTracker()
        tracker.began(translationY: 0, hidden: false)
        #expect(tracker.changed(translationY: -10, contentOffsetY: 500) == true)

        tracker.ended()

        // A rebound may move contentOffset substantially, but it supplies no
        // new finger translation and therefore cannot reverse the controls.
        #expect(tracker.changed(translationY: -10, contentOffsetY: 450) == nil)
    }

    @Test func controlsStayVisibleNearTop() {
        var tracker = ArticleChromeScrollTracker()
        tracker.began(translationY: 0, hidden: true)

        #expect(tracker.changed(translationY: -10, contentOffsetY: 20) == false)
    }
}
