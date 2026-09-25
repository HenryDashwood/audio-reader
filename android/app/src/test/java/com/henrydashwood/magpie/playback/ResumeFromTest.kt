package com.henrydashwood.magpie.playback

import org.junit.Assert.assertEquals
import org.junit.Test

class ResumeFromTest {
    @Test fun theFirstSecondsAndAnEpisodesOutroStartFromTheBeginning() {
        assertEquals(0L, resumeFrom(5_000, 600_000))
        assertEquals(5_001L, resumeFrom(5_001, 600_000))
        assertEquals(0L, resumeFrom(590_000, 600_000))
        assertEquals(589_999L, resumeFrom(589_999, 600_000))
        assertEquals(590_000L, resumeFrom(590_000, null)) // unknown length: keep the place
    }
}
