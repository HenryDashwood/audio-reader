package com.henrydashwood.magpie.ui

/**
 * Port of the iOS reader's `ArticleChromeScrollTracker`: the bars leave while she drags
 * down the page and return after a deliberate upward drag, or near the top. Distances
 * are in dp; a positive translation means the finger moved down (the page scrolls up).
 */
class ArticleChromeTracker {
    private var anchor: Float? = null
    private var hidden = false

    fun began(translation: Float, hidden: Boolean) { anchor = translation; this.hidden = hidden }

    /** A new hidden state only when the drag crosses from one state to the other. */
    fun changed(translation: Float, offset: Float): Boolean? {
        val start = anchor ?: run { anchor = translation; return null }
        // Near the top the controls stay available, whatever the direction.
        if (offset <= TOP) {
            anchor = translation
            if (!hidden) return null
            hidden = false; return false
        }
        val travelled = translation - start
        if (hidden) {
            if (travelled < 0) { anchor = translation; return null }
            if (travelled < SHOW) return null
            hidden = false; anchor = translation; return false
        }
        if (travelled > 0) { anchor = translation; return null }
        if (travelled > -HIDE) return null
        hidden = true; anchor = translation; return true
    }

    fun ended() { anchor = null }

    companion object {
        const val HIDE = 8f
        /** Returning takes a more deliberate reversal, so a wobbling thumb does not flash the bars. */
        const val SHOW = 24f
        const val TOP = 32f
    }
}
