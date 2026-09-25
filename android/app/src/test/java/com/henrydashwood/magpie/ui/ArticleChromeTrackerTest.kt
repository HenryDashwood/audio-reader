package com.henrydashwood.magpie.ui

import org.junit.Assert.*
import org.junit.Test

class ArticleChromeTrackerTest {
    @Test fun readingDownHidesAndADeliberateReversalShows() {
        val tracker = ArticleChromeTracker()
        tracker.began(0f, hidden = false)
        assertNull(tracker.changed(-5f, 500f))
        assertEquals(true, tracker.changed(-9f, 500f))
        assertNull(tracker.changed(-40f, 500f)) // continuing down is silent
        assertNull(tracker.changed(-20f, 500f)) // a 20dp wobble back up is not enough
        assertEquals(false, tracker.changed(-15f, 500f)) // 25dp up from the lowest point
    }
    @Test fun nearTheTopTheBarsAlwaysReturn() {
        val tracker = ArticleChromeTracker()
        tracker.began(0f, hidden = true)
        assertEquals(false, tracker.changed(-50f, 20f))
        assertNull(tracker.changed(-60f, 10f))
    }
    @Test fun eachDragStartsFromItsOwnAnchor() {
        val tracker = ArticleChromeTracker()
        tracker.began(0f, hidden = false)
        assertEquals(true, tracker.changed(-10f, 400f))
        tracker.ended()
        tracker.began(0f, hidden = true)
        assertNull(tracker.changed(10f, 400f))
        assertEquals(false, tracker.changed(24f, 400f))
    }
}
