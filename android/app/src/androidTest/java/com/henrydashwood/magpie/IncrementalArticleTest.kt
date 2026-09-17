package com.henrydashwood.magpie

import androidx.media3.common.MediaItem
import androidx.media3.common.Player
import androidx.media3.exoplayer.DefaultLoadControl
import androidx.media3.exoplayer.ExoPlayer
import androidx.test.core.app.ApplicationProvider
import com.henrydashwood.magpie.data.ContentKind
import com.henrydashwood.magpie.data.LibraryItem
import com.henrydashwood.magpie.playback.*
import kotlinx.coroutines.*
import org.junit.After
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder

@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
class IncrementalArticleTest {
    private val app get() = ApplicationProvider.getApplicationContext<MagpieTestApplication>()
    private var renderer: ArticleRenderer? = null
    private var player: ExoPlayer? = null
    private class Voice : ArticleVoice {
        override val name = "deterministic offline fixture"
        val requests = mutableListOf<TextChunk>()
        var gate: CompletableDeferred<Unit>? = null
        var blockAfter = Int.MAX_VALUE
        var failAfter = Int.MAX_VALUE
        var closed = false
        override suspend fun synthesize(chunk: TextChunk, destination: File): List<SpeechFrame> {
            requests += chunk
            if (requests.size > blockAfter) gate?.await()
            check(requests.size <= failAfter) { "Fixture voice failure" }
            val bytes = 32_000 // Two seconds of local, silent 8 kHz mono PCM.
            val buffer = ByteBuffer.allocate(44 + bytes).order(ByteOrder.LITTLE_ENDIAN)
            buffer.put("RIFF".toByteArray()).putInt(36 + bytes).put("WAVEfmt ".toByteArray()).putInt(16)
                .putShort(1).putShort(1).putInt(8_000).putInt(16_000).putShort(2).putShort(16)
                .put("data".toByteArray()).putInt(bytes)
            withContext(Dispatchers.IO) { destination.writeBytes(buffer.array()) }
            return listOf(SpeechFrame(0, 0, minOf(4, chunk.text.length)))
        }
        override fun close() { closed = true }
    }
    private val item get() = LibraryItem("long", "Publication", "Long article", "", ContentKind.Article, "",
        ("A café 🌱 beside the river offers a quiet place to read the next passage. ").repeat(700), contentVersion = "fixture-v1")
    private fun engine(voice: Voice) = ArticleRenderer(app) { voice }.also { renderer = it }
    private fun player(renderer: ArticleRenderer): ExoPlayer = ExoPlayer.Builder(app)
        .setMediaSourceFactory(ArticleMediaSourceFactory(app, renderer))
        .setLoadControl(DefaultLoadControl.Builder().setBufferDurationsMs(500, 1_000, 100, 100).build())
        .build().also { player = it }
    private suspend fun waitFor(predicate: () -> Boolean) { withTimeout(15_000) { while (!predicate()) delay(20) } }
    @After fun cleanup() { runBlocking(Dispatchers.Main) { renderer?.close(); player?.release() } }

    @Test fun longArticleStartsWhileLaterAudioIsStillUnavailableAndRemainsOneItem() = runBlocking(Dispatchers.Main) {
        val voice = Voice().apply { blockAfter = 1; gate = CompletableDeferred() }
        val renderer = engine(voice)
        val audio = renderer.render(item) { _, _ -> }
        assertTrue(item.text.length > 30_000)
        assertEquals(1, voice.requests.size)
        val player = player(renderer)
        player.setMediaItem(MediaItem.Builder().setMediaId(item.id).setUri(audio.uri).build())
        player.prepare(); player.play()
        waitFor { player.isPlaying }
        assertEquals(1, player.mediaItemCount)
        assertEquals(item.id, player.currentMediaItem!!.mediaId)
        assertEquals(audio.textChunks.size, player.currentTimeline.periodCount)
        assertTrue(voice.requests.size <= 2)
        assertFalse(player.playbackState == Player.STATE_ENDED)
        assertEquals(0, bookmarkAt(audio.playerChunks(player.currentTimeline), player.currentPosition, item.contentVersion)!!.offsetUtf16)
    }

    @Test fun resumeAndSeekUseTextPassagesWithoutSynthesizingEarlierChapters() = runBlocking(Dispatchers.Main) {
        val voice = Voice()
        val renderer = engine(voice)
        val offset = 35_000
        val audio = renderer.render(item, startOffset = offset) { _, _ -> }
        val index = audio.textChunks.indexOfLast { it.startUtf16 <= offset }
        assertEquals(audio.textChunks[index], voice.requests.single())
        val player = player(renderer)
        val start = resumeAt(audio.chunks, ArticleBookmark(item.contentVersion, offset), item.contentVersion)
        player.setMediaItem(MediaItem.Builder().setMediaId(item.id).setUri(audio.uri).build(), start)
        player.prepare(); player.play()
        waitFor { player.isPlaying }
        assertEquals(index, player.currentPeriodIndex)
        assertEquals(audio.textChunks[index].startUtf16,
            bookmarkAt(audio.playerChunks(player.currentTimeline), player.currentPosition, item.contentVersion)!!.offsetUtf16)
        assertTrue(voice.requests.all { it.startUtf16 >= audio.textChunks[index].startUtf16 })
        player.pause(); player.seekTo(0)
        waitFor { player.currentPeriodIndex == 0 && player.playbackState == Player.STATE_READY }
        assertTrue(voice.requests.any { it.startUtf16 == 0 })
        assertEquals(0, bookmarkAt(audio.playerChunks(player.currentTimeline), player.currentPosition, item.contentVersion)!!.offsetUtf16)
    }

    @Test fun cacheIsBoundedAndNeverEvictsAnOpenReader() = runBlocking(Dispatchers.Main) {
        val audio = engine(Voice()).render(item) { _, _ -> }
        val pinned = audio.acquire(0)
        for (index in 1..15) audio.acquire(index).close()
        assertTrue(pinned.file.isFile)
        assertTrue(audio.cachedFileCount <= 6)
        assertTrue(pinned.file.parentFile!!.listFiles()!!.size <= 6)
        pinned.close(); audio.close()
        assertFalse(pinned.file.parentFile!!.exists())
    }

    @Test fun cancellingStartupClosesTheVoiceAndDiscardsPartialAudio() = runBlocking(Dispatchers.Main) {
        val voice = Voice().apply { blockAfter = 0; gate = CompletableDeferred() }
        val renderer = engine(voice)
        val work = launch { renderer.render(item) { _, _ -> } }
        waitFor { voice.requests.isNotEmpty() }
        work.cancelAndJoin()
        assertTrue(voice.closed)
    }

    @Test fun closingTheArticleCancelsALoaderWaitingForItsNextPassage() = runBlocking(Dispatchers.Main) {
        val voice = Voice().apply { blockAfter = 1; gate = CompletableDeferred() }
        val audio = engine(voice).render(item) { _, _ -> }
        val initial = audio.acquire(0)
        val directory = initial.file.parentFile!!
        initial.close()
        val waiting = async { audio.acquire(1) }
        waitFor { voice.requests.size == 2 }
        audio.close()
        try { waiting.await(); fail("A closed article must cancel its pending loader") }
        catch (_: CancellationException) { }
        assertTrue(voice.closed)
        waitFor { !directory.exists() }
    }

    @Test fun laterVoiceFailureIsAPlaybackErrorAndNeverArticleCompletion() = runBlocking(Dispatchers.Main) {
        val voice = Voice().apply { failAfter = 1 }
        val renderer = engine(voice)
        val audio = renderer.render(item) { _, _ -> }
        val player = player(renderer)
        var ended = false
        player.addListener(object : Player.Listener {
            override fun onPlaybackStateChanged(playbackState: Int) { if (playbackState == Player.STATE_ENDED) ended = true }
        })
        player.setMediaItem(MediaItem.Builder().setMediaId(item.id).setUri(audio.uri).build())
        player.prepare(); player.play()
        waitFor { player.playerError != null }
        assertFalse(ended)
    }
}
