package com.henrydashwood.magpie

import android.content.ComponentName
import android.os.Bundle
import android.os.SystemClock
import androidx.activity.compose.setContent
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Density
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.lifecycle.Lifecycle
import androidx.media3.session.MediaController
import androidx.media3.session.SessionCommand
import androidx.media3.session.SessionToken
import com.henrydashwood.magpie.playback.PlaybackService
import com.henrydashwood.magpie.playback.PlaybackStatus
import com.henrydashwood.magpie.playback.SleepTimerState
import com.henrydashwood.magpie.ui.MagpieTheme
import com.henrydashwood.magpie.ui.SleepTimerButton
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.util.concurrent.TimeUnit

class SleepTimerTest {
    @get:Rule val compose = createAndroidComposeRule<MainActivity>()

    private fun connect(): MediaController = compose.runOnUiThread {
        val context = compose.activity.applicationContext
        MediaController.Builder(context, SessionToken(context, ComponentName(context, PlaybackService::class.java))).buildAsync()
    }.get(10, TimeUnit.SECONDS)

    private fun command(controller: MediaController, action: String, args: Bundle = Bundle.EMPTY): Int = compose.runOnUiThread {
        controller.sendCustomCommand(SessionCommand(action, Bundle.EMPTY), args)
    }.get(10, TimeUnit.SECONDS).resultCode

    private fun timer(controller: MediaController, duration: Long): Int = command(controller, PlaybackService.SET_SLEEP_TIMER,
        Bundle().apply { putLong(PlaybackService.SLEEP_DURATION_MS, duration) })

    private fun play(controller: MediaController) {
        assertEquals(0, command(controller, PlaybackService.PLAY_ITEM, Bundle().apply { putString("id", "welcome") }))
        compose.waitUntil(10_000) { compose.runOnUiThread { controller.isPlaying } }
        compose.runOnUiThread { controller.seekTo(0) }
    }

    private fun close(controller: MediaController) {
        command(controller, PlaybackService.CANCEL_SLEEP_TIMER)
        compose.runOnUiThread { controller.pause(); controller.setPlaybackSpeed(1f); controller.release() }
    }

    @Test fun expiryPausesTheServiceInBackgroundAndKeepsThePlaybackPosition() {
        val controller = connect()
        try {
            play(controller)
            compose.runOnUiThread { controller.setPlaybackSpeed(1.5f) }
            assertEquals(0, timer(controller, 2_000))
            compose.activityRule.scenario.moveToState(Lifecycle.State.CREATED)
            compose.waitUntil(6_000) { !PlaybackStatus.sleepTimer.value.running && compose.runOnUiThread { !controller.playWhenReady } }
            val position = compose.runOnUiThread { controller.currentPosition }
            assertTrue("Timer should pause after playback advanced", position > 1_000)
            compose.activityRule.scenario.moveToState(Lifecycle.State.RESUMED)
            compose.activityRule.scenario.recreate()
            assertFalse(PlaybackStatus.sleepTimer.value.running)
            assertEquals(position, compose.runOnUiThread { controller.currentPosition })
            compose.runOnUiThread { controller.play() }
            compose.waitUntil(5_000) { compose.runOnUiThread { controller.isPlaying && controller.currentPosition > position } }
        } finally { close(controller) }
    }

    @Test fun replacementCancellationAndInvalidCommandsDoNotStopPlayback() {
        val controller = connect()
        try {
            play(controller)
            assertEquals(0, timer(controller, 500))
            assertEquals(0, timer(controller, 2_500))
            val deadline = PlaybackStatus.sleepTimer.value.deadlineMs
            assertTrue(timer(controller, -1) < 0)
            assertEquals(deadline, PlaybackStatus.sleepTimer.value.deadlineMs)
            val afterFirstDeadline = SystemClock.elapsedRealtime() + 800
            compose.waitUntil(3_000) { SystemClock.elapsedRealtime() >= afterFirstDeadline }
            assertTrue(PlaybackStatus.sleepTimer.value.running)
            assertTrue(compose.runOnUiThread { controller.isPlaying })
            assertEquals(0, command(controller, PlaybackService.CANCEL_SLEEP_TIMER))
            compose.waitUntil(4_000) { SystemClock.elapsedRealtime() > checkNotNull(deadline) + 100 }
            assertFalse(PlaybackStatus.sleepTimer.value.running)
            assertTrue(compose.runOnUiThread { controller.isPlaying })
        } finally { close(controller) }
    }

    @Test fun expiryStopsArticlePreparationAndDoesNotRestartPausedAudio() {
        val controller = connect()
        try {
            play(controller)
            assertEquals(0, command(controller, PlaybackService.PLAY_ITEM, Bundle().apply { putString("id", "walking") }))
            assertEquals(0, timer(controller, 100))
            compose.waitUntil(5_000) { !PlaybackStatus.sleepTimer.value.running && PlaybackStatus.state.value.message == null }
            assertFalse(compose.runOnUiThread { controller.playWhenReady })
            val later = SystemClock.elapsedRealtime() + 1_000
            compose.waitUntil(3_000) { SystemClock.elapsedRealtime() > later }
            assertFalse(compose.runOnUiThread { controller.playWhenReady })
            assertNull(PlaybackStatus.state.value.message)
            assertEquals(0, timer(controller, 100))
            compose.waitUntil(3_000) { !PlaybackStatus.sleepTimer.value.running }
            assertFalse(compose.runOnUiThread { controller.playWhenReady })
        } finally { close(controller) }
    }

    @Test fun playerOffersIosDurationsAndTimerSurvivesClosingAndRecreation() {
        val controller = connect()
        try {
            play(controller)
            compose.onNodeWithTag("mini-player-open").performClick()
            compose.onNodeWithContentDescription("Sleep timer").performScrollTo().performClick()
            for (minutes in listOf(5, 10, 15, 30, 45, 60)) compose.onNodeWithText("$minutes minutes").assertExists()
            compose.onNodeWithText("5 minutes").performClick()
            compose.waitUntil(3_000) { PlaybackStatus.sleepTimer.value.remainingMinutes == 5 }
            val deadline = PlaybackStatus.sleepTimer.value.deadlineMs
            compose.onNodeWithContentDescription("Sleep timer").assert(SemanticsMatcher.expectValue(SemanticsProperties.StateDescription, "Stopping in 5 minutes"))
            compose.onNodeWithContentDescription("Close player").performScrollTo().performClick()
            compose.activityRule.scenario.recreate()
            compose.onNodeWithTag("mini-player-open").performClick()
            assertEquals(deadline, PlaybackStatus.sleepTimer.value.deadlineMs)
            compose.onNodeWithContentDescription("Sleep timer").performScrollTo().performClick()
            compose.onNodeWithText("Turn off sleep timer").performClick()
            compose.waitUntil(3_000) { !PlaybackStatus.sleepTimer.value.running }
            compose.onNodeWithContentDescription("Sleep timer").assert(SemanticsMatcher.expectValue(SemanticsProperties.StateDescription, "Off"))
        } finally { close(controller) }
    }

    @Test fun timerControlRemainsUsableWithLargeTextAndDarkTheme() {
        val state = mutableStateOf(SleepTimerState())
        compose.runOnUiThread {
            compose.activity.setContent {
                val density = LocalDensity.current.density
                CompositionLocalProvider(LocalDensity provides Density(density, 2f)) {
                    MagpieTheme(darkTheme = true) {
                        SleepTimerButton(state.value, true,
                            { state.value = SleepTimerState(1_000, it) }, { state.value = SleepTimerState() })
                    }
                }
            }
        }
        compose.onNodeWithContentDescription("Sleep timer").assertIsDisplayed().performClick()
        compose.onNodeWithText("60 minutes").performScrollTo().performClick()
        compose.onNodeWithContentDescription("Sleep timer").assertIsDisplayed()
            .assert(SemanticsMatcher.expectValue(SemanticsProperties.StateDescription, "Stopping in 60 minutes"))
            .performClick()
        compose.onNodeWithText("Turn off sleep timer").performScrollTo().performClick()
        compose.onNodeWithContentDescription("Sleep timer").assert(SemanticsMatcher.expectValue(SemanticsProperties.StateDescription, "Off"))
    }
}
