package com.henrydashwood.magpie

import android.content.ComponentName
import android.graphics.Bitmap
import android.os.Bundle
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.*
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import androidx.media3.session.MediaController
import androidx.media3.session.SessionCommand
import androidx.media3.session.SessionToken
import androidx.test.platform.app.InstrumentationRegistry
import com.henrydashwood.magpie.data.PreviewStore
import com.henrydashwood.magpie.data.RichArticleSample
import com.henrydashwood.magpie.playback.PlaybackService
import com.henrydashwood.magpie.playback.PlaybackStatus
import com.henrydashwood.magpie.ui.MagpieTheme
import com.henrydashwood.magpie.ui.MiniPlayer
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.io.File
import java.util.concurrent.TimeUnit

class MiniPlayerTest {
    @get:Rule val compose = createAndroidComposeRule<MainActivity>()

    private fun connect(): MediaController = compose.runOnUiThread {
        val context = compose.activity.applicationContext
        MediaController.Builder(context, SessionToken(context, ComponentName(context, PlaybackService::class.java))).buildAsync()
    }.get(10, TimeUnit.SECONDS)

    private fun command(controller: MediaController, action: String, args: Bundle = Bundle.EMPTY) {
        val result = compose.runOnUiThread { controller.sendCustomCommand(SessionCommand(action, Bundle.EMPTY), args) }
        assertEquals(0, result.get(10, TimeUnit.SECONDS).resultCode)
    }

    private fun play(controller: MediaController, id: String) = command(controller, PlaybackService.PLAY_ITEM, Bundle().apply { putString("id", id) })

    private fun closeFromBar(controller: MediaController) {
        compose.waitUntil(10_000) { compose.onAllNodesWithContentDescription("Stop and close player").fetchSemanticsNodes().isNotEmpty() }
        compose.onNode(hasContentDescription("Stop and close player") and hasAnyAncestor(hasTestTag("mini-player"))).performClick()
        compose.waitUntil(5_000) { compose.runOnUiThread { !controller.isPlaying && controller.mediaItemCount == 0 } }
        compose.onNodeWithTag("mini-player").assertDoesNotExist()
        assertNull(PlaybackStatus.readingPosition.value)
        assertNull(PlaybackStatus.state.value.message)
    }

    @Test fun dismissStopsPlaybackClearsTimerAndRestoreButKeepsBookmark() {
        val controller = connect()
        try {
            play(controller, "welcome")
            compose.waitUntil(10_000) { compose.runOnUiThread { controller.isPlaying } }
            compose.runOnUiThread { controller.seekTo(7_000); controller.pause() }
            command(controller, PlaybackService.SET_SLEEP_TIMER, Bundle().apply { putLong(PlaybackService.SLEEP_DURATION_MS, 60_000) })
            closeFromBar(controller)
            val store = PreviewStore(compose.activity)
            val bookmark = store.position("welcome")
            assertTrue(bookmark >= 7_000)
            assertNull(store.lastItem)
            assertFalse(PlaybackStatus.sleepTimer.value.running)
            compose.activityRule.scenario.recreate()
            compose.onNodeWithTag("mini-player").assertDoesNotExist()
            play(controller, "welcome")
            compose.waitUntil(10_000) { compose.runOnUiThread { controller.isPlaying && controller.currentPosition >= bookmark } }
            compose.onNodeWithTag("mini-player-open").assertIsDisplayed()
            closeFromBar(controller)
        } finally { compose.runOnUiThread { controller.pause(); controller.release() } }
    }

    @Test fun dismissDuringPreparationCannotStartAudioOrReplaceNextItem() {
        val controller = connect()
        try {
            play(controller, "rich-reading")
            closeFromBar(controller)
            assertNull(PreviewStore(compose.activity).lastItem)
            play(controller, "welcome")
            compose.runOnUiThread { controller.seekTo(0) }
            compose.waitUntil(10_000) { compose.runOnUiThread { controller.isPlaying && controller.currentPosition > 1500 } }
            assertEquals("welcome", compose.runOnUiThread { controller.currentMediaItem?.mediaId })
            closeFromBar(controller)
        } finally { compose.runOnUiThread { controller.pause(); controller.release() } }
    }

    private fun screenshot(name: String) {
        compose.waitForIdle()
        val bitmap = checkNotNull(InstrumentationRegistry.getInstrumentation().uiAutomation.takeScreenshot())
        val supplied = InstrumentationRegistry.getArguments().getString("additionalTestOutputDir")
        val directory = (supplied?.let(::File) ?: File(compose.activity.filesDir, "screenshots")).apply { mkdirs() }
        File(directory, "$name.png").outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
        bitmap.recycle()
    }

    @Test fun nativeControlsStaySeparateAndReachableAtLargeTextOnNarrowScreens() {
        val scale = mutableFloatStateOf(1f)
        var opened = 0; var followed = 0; var toggled = 0; var dismissed = 0
        compose.runOnUiThread { compose.activity.setContent {
            CompositionLocalProvider(LocalDensity provides Density(LocalDensity.current.density, scale.floatValue)) {
                MagpieTheme(darkTheme = scale.floatValue > 1f) {
                    Box(Modifier.fillMaxSize()) {
                        Box(Modifier.align(Alignment.BottomCenter).width(if (scale.floatValue > 1f) 320.dp else 400.dp).navigationBarsPadding()) {
                            MiniPlayer(PlayerState(item = RichArticleSample.item, connected = true, durationMs = 100, positionMs = 40),
                                false, { opened++ }, { toggled++ }, { dismissed++ }, { followed++ })
                        }
                    }
                }
            }
        } }
        for (font in listOf(1f, 2f)) {
            compose.runOnIdle { scale.floatValue = font }
            compose.onNodeWithTag("mini-player-open").assertIsDisplayed().performClick()
            val actions = listOf("Follow reading position", "Resume playback", "Stop and close player")
            for (label in actions) {
                val node = compose.onNodeWithContentDescription(label)
                node.assertIsDisplayed().assertWidthIsAtLeast(48.dp).assertHeightIsAtLeast(48.dp).performClick()
            }
            val bounds = actions.map { compose.onNodeWithContentDescription(it).fetchSemanticsNode().boundsInRoot }
            assertTrue(bounds.zipWithNext().all { (left, right) -> left.right <= right.left })
            screenshot(if (font == 1f) "mini-player-controls" else "mini-player-large-dark")
        }
        assertEquals(2, opened); assertEquals(2, followed); assertEquals(2, toggled); assertEquals(2, dismissed)
    }
}
