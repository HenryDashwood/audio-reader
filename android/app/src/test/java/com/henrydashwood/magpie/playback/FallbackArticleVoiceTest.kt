package com.henrydashwood.magpie.playback

import java.io.File
import java.nio.file.Files
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.NonCancellable
import org.junit.Assert.*
import org.junit.Test

class FallbackArticleVoiceTest {
    private val chunk = TextChunk("Hello there.", 0, 12)
    private val folder: File = Files.createTempDirectory("fallback").toFile()

    /** Writes `content` to the destination, or runs `behaviour` instead. */
    private class FakeVoice(override val name: String, private val content: String,
        private val behaviour: (suspend () -> Unit)? = null) : ArticleVoice {
        var calls = 0
        var closed = false
        override suspend fun synthesize(chunk: TextChunk, destination: File): List<SpeechFrame> {
            calls++
            behaviour?.invoke()
            destination.writeText(content)
            return listOf(SpeechFrame(0, 0, 5))
        }
        override fun close() { closed = true }
    }

    @Test fun theNaturalVoiceReadsWhenItWorks() = runBlocking {
        val natural = FakeVoice("natural:bf_emma", "natural")
        var opened = 0
        val voice = FallbackArticleVoice(natural, abandon = { fail("Nothing hung") }) { opened++; FakeVoice("google", "google") }
        val destination = File(folder, "a.wav")
        voice.synthesize(chunk, destination)
        assertEquals("natural", destination.readText())
        assertEquals("natural:bf_emma", voice.name)
        assertEquals(0, opened)
        assertFalse(File(destination.path + ".natural").exists())
    }

    @Test fun aFailedPassageIsReadWithTheGoogleVoiceAndTheNextTriesNaturalAgain() = runBlocking {
        var failing = true
        val natural = FakeVoice("natural:bf_emma", "natural") { if (failing) error("GPU lost") }
        val google = FakeVoice("google", "google")
        var opened = 0
        val voice = FallbackArticleVoice(natural, abandon = { fail("Nothing hung") }) { opened++; google }
        val first = File(folder, "1.wav")
        voice.synthesize(chunk, first)
        assertEquals("google", first.readText())
        failing = false
        val second = File(folder, "2.wav")
        voice.synthesize(chunk, second)
        assertEquals("natural", second.readText())
        assertEquals(2, natural.calls)
        assertEquals(1, opened)
        voice.close()
        assertTrue(natural.closed && google.closed)
    }

    @Test fun aHungRenderIsAbandonedAndCannotOverwriteTheFallbackLater() = runBlocking {
        val release = CompletableDeferred<Unit>()
        val natural = FakeVoice("natural:bf_emma", "late natural") {
            // A native call ignores cancellation: it finishes, and writes, when it finishes.
            withContext(NonCancellable) { release.await() }
        }
        var abandoned = 0
        val voice = FallbackArticleVoice(natural, limit = { 200L }, abandon = { abandoned++ }) { FakeVoice("google", "google") }
        val destination = File(folder, "hung.wav")
        voice.synthesize(chunk, destination)
        assertEquals(1, abandoned)
        assertEquals("google", destination.readText())
        release.complete(Unit)
        Thread.sleep(200)
        assertEquals("google", destination.readText())
    }

    @Test fun cancellingTheReaderDoesNotFallBack() = runBlocking {
        val natural = FakeVoice("natural:bf_emma", "natural") { awaitCancellation() }
        var opened = 0
        val voice = FallbackArticleVoice(natural, abandon = {}) { opened++; FakeVoice("google", "google") }
        val job = launch { voice.synthesize(chunk, File(folder, "cancel.wav")) }
        Thread.sleep(100)
        job.cancel()
        job.join()
        assertEquals(0, opened)
    }
}
