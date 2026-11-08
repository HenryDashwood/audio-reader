package com.henrydashwood.magpie.playback

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class IdleReleaseTest {
    @Test fun releasesOnlyAfterStayingStill() = runTest {
        var released = 0
        val idle = IdleRelease(backgroundScope, after = 1_000) { released++ }
        idle.playing(false)
        advanceTimeBy(999); runCurrent()
        assertEquals(0, released)
        advanceTimeBy(1); runCurrent()
        assertEquals(1, released)
    }

    @Test fun playingAgainKeepsTheVoice() = runTest {
        var released = 0
        val idle = IdleRelease(backgroundScope, after = 1_000) { released++ }
        idle.playing(false)
        advanceTimeBy(900); runCurrent()
        idle.playing(true)
        advanceTimeBy(5_000); runCurrent()
        assertEquals(0, released)
        idle.playing(false)  // A fresh pause waits the whole time again
        advanceTimeBy(900); runCurrent()
        idle.playing(false)
        advanceTimeBy(900); runCurrent()
        assertEquals(0, released)
        advanceTimeBy(100); runCurrent()
        assertEquals(1, released)
    }

    @Test fun cancelStopsAPendingRelease() = runTest {
        var released = 0
        val idle = IdleRelease(backgroundScope, after = 1_000) { released++ }
        idle.playing(false)
        idle.cancel()
        advanceTimeBy(5_000); runCurrent()
        assertEquals(0, released)
    }
}
