package com.henrydashwood.magpie

import android.content.ComponentName
import android.os.Bundle
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.ViewModelProvider
import androidx.media3.session.MediaController
import androidx.media3.session.SessionCommand
import androidx.media3.session.SessionToken
import com.henrydashwood.magpie.data.PreviewStore
import com.henrydashwood.magpie.playback.PlaybackService
import com.henrydashwood.magpie.playback.PlaybackStatus
import org.junit.After
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import java.util.concurrent.TimeUnit

class PlaybackCompletionTest {
    @get:Rule val compose = createAndroidComposeRule<MainActivity>()
    private lateinit var controller: MediaController
    private lateinit var store: PreviewStore
    private lateinit var previousFinished: Set<String>
    private lateinit var previousSaved: Set<String>

    @Before fun connect() {
        controller = compose.runOnUiThread {
            val context = compose.activity.applicationContext
            MediaController.Builder(context, SessionToken(context, ComponentName(context, PlaybackService::class.java))).buildAsync()
        }.get(10, TimeUnit.SECONDS)
        store = PreviewStore(compose.activity)
        previousFinished = store.finished
        previousSaved = store.saved
        command(PlaybackService.DISMISS_PLAYER)
        store.finished = store.finished - setOf("welcome", "morning")
        store.savePosition("welcome", 0)
    }

    @After fun disconnect() {
        command(PlaybackService.DISMISS_PLAYER)
        store.finished = previousFinished
        store.saved = previousSaved
        compose.runOnUiThread { controller.release() }
    }

    private fun command(action: String, args: Bundle = Bundle.EMPTY) {
        val result = compose.runOnUiThread { controller.sendCustomCommand(SessionCommand(action, Bundle.EMPTY), args) }
        assertEquals(0, result.get(10, TimeUnit.SECONDS).resultCode)
    }

    private fun play(id: String) = command(PlaybackService.PLAY_ITEM, Bundle().apply { putString("id", id) })

    private fun waitForPlayback(id: String) {
        compose.waitUntil(90_000) {
            PlaybackStatus.state.value.error != null || compose.runOnUiThread { controller.isPlaying && controller.currentMediaItem?.mediaId == id }
        }
    }

    private fun finish() {
        compose.runOnUiThread {
            assertTrue(controller.duration > 0)
            controller.seekTo(controller.duration - 200)
            controller.play()
        }
        compose.waitUntil(10_000) { compose.runOnUiThread { controller.mediaItemCount == 0 && !controller.isPlaying } }
    }

    @Test fun podcastFinishesInBackgroundAndDoesNotRestoreThePlayer() {
        play("welcome")
        waitForPlayback("welcome")
        assertNull(PlaybackStatus.state.value.error)
        command(PlaybackService.SET_SLEEP_TIMER, Bundle().apply { putLong(PlaybackService.SLEEP_DURATION_MS, 60_000) })
        compose.activityRule.scenario.moveToState(Lifecycle.State.CREATED)
        finish()
        assertTrue("Completed podcast should be recorded", "welcome" in store.finished)
        assertEquals(0L, store.position("welcome"))
        assertNull(store.lastItem)
        assertFalse(PlaybackStatus.sleepTimer.value.running)
        compose.activityRule.scenario.moveToState(Lifecycle.State.RESUMED)
        compose.activityRule.scenario.recreate()
        compose.onNodeWithTag("mini-player").assertDoesNotExist()
        play("welcome")
        waitForPlayback("welcome")
        assertTrue("Replay should start at the beginning", compose.runOnUiThread { controller.currentPosition < 5_000 })
    }

    @Test fun completedArticleMovesToFinishedAndClosesThePlayerSheet() {
        compose.runOnUiThread {
            val model = ViewModelProvider(compose.activity)[MagpieModel::class.java]
            if ("morning" !in model.saved.value) model.toggleSaved(model.library.first { it.id == "morning" })
        }
        play("morning")
        waitForPlayback("morning")
        val error = PlaybackStatus.state.value.error
        if (error != null) {
            assertTrue("Unexpected narration failure: $error", error.contains("Install Speech Recognition") || error.contains("Download an English offline voice"))
            assumeTrue("Requires an installed offline voice: $error", false)
        }
        compose.onNodeWithText("Saved").performClick()
        compose.onNodeWithTag("mini-player-open").performClick()
        finish()
        compose.waitUntil(5_000) { compose.onAllNodesWithTag("mini-player").fetchSemanticsNodes().isEmpty() }
        compose.onNodeWithContentDescription("Close player").assertDoesNotExist()
        compose.onNodeWithText("Before the rest of the day begins").assertDoesNotExist()
        compose.onNodeWithText("Finished").performClick()
        compose.onNodeWithText("Before the rest of the day begins").assertIsDisplayed()
        assertEquals(0, store.bookmark("morning")?.offsetUtf16)
        assertNull(PlaybackStatus.readingPosition.value)
        assertNull(store.lastItem)
        compose.activityRule.scenario.recreate()
        compose.onNodeWithTag("mini-player").assertDoesNotExist()
        assertTrue("morning" in PreviewStore(compose.activity).finished)
    }

    @Test fun pausingOrClosingAnUnfinishedItemDoesNotMarkItFinished() {
        play("welcome")
        waitForPlayback("welcome")
        compose.runOnUiThread { controller.seekTo(5_000); controller.pause() }
        command(PlaybackService.DISMISS_PLAYER)
        assertFalse("welcome" in store.finished)
        assertTrue(store.position("welcome") >= 5_000)
        assertNull(store.lastItem)
    }
}
