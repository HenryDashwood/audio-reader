package com.henrydashwood.magpie.playback

import org.junit.Assert.*
import org.junit.Test

class SleepTimerTest {
    @Test fun countsDownRealElapsedTimeAndRoundsUpTheLastMinute() {
        var now = 100L
        var expired = 0
        val timer = SleepTimer({ now }, expired = { expired++ })
        assertTrue(timer.start(300_000))
        assertEquals(5, timer.state.remainingMinutes)
        now += 60_001
        timer.check()
        assertEquals(4, timer.state.remainingMinutes)
        now = 300_099
        timer.check()
        assertEquals(1, timer.state.remainingMinutes)
        assertEquals(0, expired)
        now++
        timer.check()
        assertFalse(timer.state.running)
        assertNull(timer.state.remainingMinutes)
        assertEquals(1, expired)
        timer.check()
        assertEquals(1, expired)
    }

    @Test fun replacementCannotExpireAtTheOldDeadline() {
        var now = 0L
        var expired = 0
        val timer = SleepTimer({ now }, expired = { expired++ })
        timer.start(1_000)
        now = 500
        timer.start(5_000)
        now = 1_001
        timer.check()
        assertTrue(timer.state.running)
        assertEquals(0, expired)
        now = 5_500
        timer.check()
        assertEquals(1, expired)
    }

    @Test fun cancelledTimerNeverExpiresAndCanBeRestarted() {
        var now = 0L
        var expired = 0
        val timer = SleepTimer({ now }, expired = { expired++ })
        timer.start(1_000)
        timer.cancel()
        now = 5_000
        timer.check()
        assertEquals(0, expired)
        timer.start(1_000)
        now = 6_000
        timer.check()
        assertEquals(1, expired)
    }

    @Test fun lateWakeExpiresOnceAndPublishesOffBeforePausing() {
        var now = 0L
        val updates = mutableListOf<SleepTimerState>()
        var expired = 0
        val timer = SleepTimer({ now }, updates::add) { assertFalse(updates.last().running); expired++ }
        timer.start(5_000)
        now = 600_000 // Device slept while playback was already paused.
        timer.check()
        timer.check()
        assertEquals(1, expired)
        assertEquals(SleepTimerState(), updates.last())
    }

    @Test fun invalidDurationsLeaveAnExistingTimerUnchanged() {
        val timer = SleepTimer({ 0 }, expired = {})
        timer.start(60_000)
        val original = timer.state
        for (invalid in listOf(0L, -1L, Long.MAX_VALUE, SleepTimer.MAX_DURATION_MS + 1)) {
            assertFalse(timer.start(invalid))
            assertEquals(original, timer.state)
        }
    }
}
