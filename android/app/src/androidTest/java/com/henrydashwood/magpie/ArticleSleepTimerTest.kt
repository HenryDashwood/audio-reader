package com.henrydashwood.magpie

import android.os.Bundle
import androidx.lifecycle.ViewModelProvider
import androidx.media3.session.SessionCommand
import com.henrydashwood.magpie.data.RemoteArticleBookmark
import com.henrydashwood.magpie.playback.*
import java.io.File
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import org.junit.After
import org.junit.Assert.*
import org.junit.Test

class ArticleSleepTimerTest : ArticleProgressPlaybackFixture() {
    override val preloadText = false
    private enum class Stage { InitialFetch, BookmarkRefresh, FirstSentence }
    private val entered = CompletableDeferred<Unit>()
    private val release = CompletableDeferred<Unit>()
    private val returned = CompletableDeferred<Unit>()
    private lateinit var stage: Stage
    private var offset = 0
    private val sentences = mutableListOf<Int>()

    // Even a result that finishes after cancellation must not start the player.
    private suspend fun holdResult() {
        entered.complete(Unit)
        withContext(NonCancellable) { release.await() }
        returned.complete(Unit)
    }

    override fun configureFixture() {
        offset = api.body.indexOf("A café", 200)
        api.row = api.row.copy(articleBookmark = RemoteArticleBookmark(api.hash, offset))
        app.rendererFactory = {
            ArticleRenderer(app) {
                object : ArticleVoice {
                    override val name = "Controlled article voice"
                    override suspend fun synthesize(chunk: TextChunk, destination: File): List<SpeechFrame> {
                        sentences += chunk.startUtf16
                        writeWave(destination, FloatArray(32_000), 8_000)
                        if (stage == Stage.FirstSentence && sentences.size == 1) holdResult()
                        return emptyList()
                    }
                    override fun close() = Unit
                }
            }
        }
    }

    @After fun releaseVoice() {
        release.complete(Unit)
        app.rendererFactory = null
    }

    @Test fun expiryDuringInitialTextFetch() = checkExpiry(Stage.InitialFetch)
    @Test fun expiryDuringBookmarkRefresh() = checkExpiry(Stage.BookmarkRefresh)
    @Test fun expiryDuringFirstSentenceRendering() = checkExpiry(Stage.FirstSentence)

    private fun checkExpiry(point: Stage) {
        stage = point
        val media = checkNotNull(controller)
        lateinit var model: MagpieModel
        scenario!!.onActivity { model = ViewModelProvider(it)[MagpieModel::class.java] }
        fun waitFor(condition: () -> Boolean) = compose.waitUntil(15_000) { compose.runOnUiThread(condition) }
        fun play() = compose.runOnUiThread { model.play(library.state.value.items.single()) }
        if (point == Stage.BookmarkRefresh) {
            runBlocking(Dispatchers.Main) { library.content(library.state.value.items.single().id) }
        }
        api.beforeText = {
            if (point != Stage.FirstSentence && !entered.isCompleted) holdResult()
        }
        waitFor { model.player.value.connected }
        play()
        waitFor { entered.isCompleted }
        val timer = compose.runOnUiThread {
            media.sendCustomCommand(SessionCommand(PlaybackService.SET_SLEEP_TIMER, Bundle.EMPTY),
                Bundle().apply { putLong(PlaybackService.SLEEP_DURATION_MS, 250) })
        }
        assertEquals(0, timer.get(10, TimeUnit.SECONDS).resultCode)
        waitFor { !PlaybackStatus.sleepTimer.value.running }
        release.complete(Unit)
        waitFor { returned.isCompleted && model.itemLoading.value == null && PlaybackStatus.state.value.message == null }
        // Give the session a chance to process a late Play from the completed fetch.
        compose.waitForIdle()
        android.os.SystemClock.sleep(350)
        compose.runOnUiThread {
            assertFalse(media.playWhenReady)
            assertNull(media.currentMediaItem)
            assertEquals(offset, library.state.value.items.single().articleBookmark?.offsetUtf16)
            assertEquals(if (point == Stage.FirstSentence) listOf(offset) else emptyList(), sentences.toList())
        }
        assertTrue(runBlocking { journal.read(library.state.value.owner!!) }.none { it.sampled })

        play()
        waitFor { media.isPlaying && media.currentPosition > 1_000 }
        compose.runOnUiThread { media.pause() }
        compose.waitUntil(10_000) {
            runBlocking { journal.read(library.state.value.owner!!) }.any { it.sampled && it.latest.offsetUtf16 == offset }
        }
        assertEquals(offset, sentences.first())
        assertEquals(if (point == Stage.InitialFetch) 2 else 3, api.textRequests)
    }
}
