import Testing
import UIKit

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

        #expect(tracker.changed(translationY: 24, contentOffsetY: 100) == false)
        #expect(tracker.changed(translationY: 34, contentOffsetY: 90) == nil)
    }

    @Test func thumbWobbleDoesNotBringControlsBackDuringAReadingGesture() {
        var tracker = ArticleChromeScrollTracker()
        tracker.began(translationY: 0, hidden: false)

        #expect(tracker.changed(translationY: -12, contentOffsetY: 100) == true)
        #expect(tracker.changed(translationY: -30, contentOffsetY: 118) == nil)
        #expect(tracker.changed(translationY: -18, contentOffsetY: 106) == nil)
        #expect(tracker.changed(translationY: -35, contentOffsetY: 123) == nil)
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

    @Test @MainActor func hidingChromeNeverDisablesTheNavigationBar() {
        let chrome = ArticleChromeController()
        let navigation = UINavigationController(rootViewController: chrome)
        navigation.loadViewIfNeeded()
        chrome.viewWillAppear(false)

        chrome.setBarsHidden(true, animated: false)

        #expect(navigation.navigationBar.alpha == 0)
        #expect(navigation.navigationBar.isUserInteractionEnabled)

        chrome.setBarsHidden(false, animated: false)

        #expect(navigation.navigationBar.alpha == 1)
        #expect(navigation.navigationBar.isUserInteractionEnabled)
    }
}
