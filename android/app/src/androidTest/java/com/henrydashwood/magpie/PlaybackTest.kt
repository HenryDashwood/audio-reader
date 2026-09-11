package com.henrydashwood.magpie

import android.content.ComponentName
import android.os.Bundle
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.lifecycle.Lifecycle
import androidx.media3.session.MediaController
import androidx.media3.session.SessionCommand
import androidx.media3.session.SessionToken
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.henrydashwood.magpie.playback.PlaybackService
import com.henrydashwood.magpie.playback.PlaybackStatus
import java.util.concurrent.TimeUnit
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class PlaybackTest {
    @get:Rule val compose = createAndroidComposeRule<MainActivity>()

    private fun connect(): MediaController {
        val future = compose.runOnUiThread {
            val context = compose.activity.applicationContext
            MediaController.Builder(context, SessionToken(context, ComponentName(context, PlaybackService::class.java))).buildAsync()
        }
        return future.get(10, TimeUnit.SECONDS)
    }

    private fun request(controller: MediaController, id: String) {
        val result = compose.runOnUiThread {
            controller.sendCustomCommand(SessionCommand(PlaybackService.PLAY_ITEM, Bundle.EMPTY), Bundle().apply { putString("id", id) })
        }.get(10, TimeUnit.SECONDS)
        assertEquals(0, result.resultCode)
    }

    @Test fun recordingSeeksChangesSpeedAndKeepsPlayingOutsideActivity() {
        val controller = connect()
        try {
            request(controller, "welcome")
            compose.waitUntil(15_000) { compose.runOnUiThread { controller.isPlaying && controller.duration > 30_000 } }
            compose.runOnUiThread { controller.seekTo(5_000); controller.setPlaybackSpeed(1.5f) }
            compose.waitUntil(5_000) { compose.runOnUiThread { controller.currentPosition >= 5_000 && controller.playbackParameters.speed == 1.5f } }
            compose.activityRule.scenario.moveToState(Lifecycle.State.CREATED)
            val position = compose.runOnUiThread { controller.currentPosition }
            compose.waitUntil(5_000) { compose.runOnUiThread { controller.isPlaying && controller.currentPosition > position + 700 } }
            compose.runOnUiThread { controller.pause() }
            compose.waitUntil(5_000) { compose.runOnUiThread { !controller.isPlaying } }
            compose.activityRule.scenario.moveToState(Lifecycle.State.RESUMED)
            compose.activityRule.scenario.recreate()
            assertFalse(compose.runOnUiThread { controller.isPlaying })
        } finally { compose.runOnUiThread { controller.pause(); controller.setPlaybackSpeed(1f); controller.release() } }
    }

    @Test fun articleEitherPlaysOneItemOrExplainsMissingOfflineVoice() {
        val controller = connect()
        try {
            request(controller, "morning")
            compose.waitUntil(90_000) {
                PlaybackStatus.state.value.error != null || compose.runOnUiThread { controller.isPlaying && controller.currentMediaItem?.mediaId == "morning" }
            }
            val error = PlaybackStatus.state.value.error
            if (error != null) {
                assertTrue("Unexpected narration failure: $error", error.contains("Install Speech Recognition") || error.contains("Download an English offline voice"))
                assertFalse(compose.runOnUiThread { controller.isPlaying })
            } else {
                assertEquals(1, compose.runOnUiThread { controller.mediaItemCount })
                assertTrue(compose.runOnUiThread { controller.duration > 0 })
                compose.waitUntil(5_000) { PlaybackStatus.readingPosition.value?.itemId == "morning" }
                compose.runOnUiThread { controller.pause(); controller.seekTo(0) }
                compose.waitUntil(5_000) { PlaybackStatus.readingPosition.value?.startUtf16 == 0 }
                val initial = PlaybackStatus.readingPosition.value!!
                compose.runOnUiThread { controller.setPlaybackSpeed(1.5f); controller.seekTo(controller.duration * 3 / 4) }
                compose.waitUntil(5_000) { (PlaybackStatus.readingPosition.value?.startUtf16 ?: 0) > initial.startUtf16 }
                val paused = PlaybackStatus.readingPosition.value
                Thread.sleep(350)
                assertEquals(paused, PlaybackStatus.readingPosition.value)
                compose.onNodeWithText("Field notes").performClick()
                compose.onNode(hasText("Before the rest of the day begins") and hasAnyAncestor(hasTestTag("story-list"))).performClick()
                compose.onNodeWithTag("article-webview").performTouchInput { swipeDown() }
                compose.onNode(hasContentDescription("Follow reading position") and hasAnyAncestor(hasTestTag("mini-player"))).assertIsDisplayed()
                compose.onNodeWithContentDescription("Back").performClick()
                compose.onNodeWithContentDescription("Follow reading position").assertDoesNotExist()
                compose.onNode(hasText("Before the rest of the day begins") and hasAnyAncestor(hasTestTag("story-list"))).performClick()
                compose.onNodeWithTag("article-webview").performTouchInput { swipeDown() }
                compose.activityRule.scenario.recreate()
                assertEquals(paused, PlaybackStatus.readingPosition.value)
                compose.onNodeWithContentDescription("Follow reading position").assertIsDisplayed()
                compose.onNodeWithContentDescription("Follow reading position").performClick()
                compose.runOnUiThread { controller.seekTo(0) }
                compose.waitUntil(5_000) { PlaybackStatus.readingPosition.value == initial }
                request(controller, "welcome")
                compose.waitUntil(5_000) { PlaybackStatus.readingPosition.value == null }
            }
        } finally { compose.runOnUiThread { controller.pause(); controller.release() } }
    }

    @Test fun cancelledArticleCannotReplaceSubsequentPodcast() {
        val controller = connect()
        try {
            request(controller, "walking")
            compose.runOnUiThread {
                controller.sendCustomCommand(SessionCommand(PlaybackService.CANCEL_PREPARATION, Bundle.EMPTY), Bundle.EMPTY)
            }.get(10, TimeUnit.SECONDS)
            request(controller, "welcome")
            compose.runOnUiThread { controller.seekTo(0) }
            compose.waitUntil(10_000) { compose.runOnUiThread { controller.isPlaying && controller.currentPosition > 1200 } }
            assertEquals("welcome", compose.runOnUiThread { controller.currentMediaItem?.mediaId })
            assertNull(PlaybackStatus.state.value.error)
            assertNull(PlaybackStatus.state.value.message)
        } finally { compose.runOnUiThread { controller.pause(); controller.release() } }
    }
}
