package com.henrydashwood.magpie.voice

import kotlinx.coroutines.*
import kotlinx.coroutines.test.*
import org.junit.Assert.*
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class SpokenReplyTest {
    private class Engine : ReplyEngine {
        override val maxCharacters = 20
        val chunks = mutableListOf<String>()
        var id = ""
        var closed = 0
        lateinit var finished: (String, String?) -> Unit
        override fun speak(text: String, id: String, finished: (String, String?) -> Unit) {
            chunks += text; this.id = id; this.finished = finished
        }
        override fun close() { closed++ }
    }

    @Test fun waitsForActualAudioCompletionOfEveryChunkAndIgnoresOldCallbacks() = runTest {
        val engine = Engine(); val speaker = SpokenReply { engine }
        val text = "Here is a reply that is longer than one short chunk."
        val result = async { speaker.speak(text) }; runCurrent()
        assertEquals(1, engine.chunks.size); assertFalse(result.isCompleted)
        val oldCallback = engine.finished; val oldId = engine.id
        engine.finished(engine.id, null); runCurrent()
        assertEquals(2, engine.chunks.size)
        oldCallback(oldId, null); runCurrent(); assertEquals(2, engine.chunks.size)
        engine.finished(oldId, null); runCurrent(); assertEquals(2, engine.chunks.size)
        while (!result.isCompleted) { engine.finished(engine.id, null); runCurrent() }
        result.await(); assertEquals(text, engine.chunks.joinToString("")); assertEquals(1, engine.closed)
    }

    @Test fun cancellationStopsSpeechAndLateCompletionCannotFinishTheNextReply() = runTest {
        val engines = mutableListOf<Engine>(); val speaker = SpokenReply { Engine().also(engines::add) }
        val first = launch { speaker.speak("First reply") }; runCurrent(); val old = engines.first()
        first.cancelAndJoin(); assertEquals(1, old.closed)
        val next = async { speaker.speak("Next reply") }; runCurrent()
        old.finished(old.id, null); runCurrent(); assertFalse(next.isCompleted)
        val current = engines.last(); current.finished(current.id, null); runCurrent(); next.await()
        assertEquals(1, current.closed)
    }

    @Test fun audioInterruptionFailsWithoutPlayingTheNextChunk() = runTest {
        val engine = Engine(); val speaker = SpokenReply { engine }
        val result = async { runCatching { speaker.speak("This reply has several chunks to play.") } }; runCurrent()
        engine.finished(engine.id, "Audio interrupted"); runCurrent()
        assertTrue(result.await().exceptionOrNull() is VoiceFailure)
        assertEquals(1, engine.chunks.size); assertEquals(1, engine.closed)
    }

    @Test fun missingEngineCallbackTimesOutAndReleasesAudio() = runTest {
        val engine = Engine(); val result = async { runCatching { SpokenReply { engine }.speak("Hello") } }; runCurrent()
        advanceTimeBy(180_000); runCurrent()
        assertTrue(result.await().exceptionOrNull() is VoiceFailure); assertEquals(1, engine.closed)
    }

    @Test fun longUnicodeTextIsSplitWithoutLossOrBrokenSurrogatePairs() {
        val text = "A🐦 greeting.\n".repeat(400)
        listOf(2, 7, 20, 4_000).forEach { limit ->
            val chunks = SpokenReply.chunks(text, limit)
            assertEquals(text, chunks.joinToString(""))
            assertTrue(chunks.all { it.length <= limit && !it.last().isHighSurrogate() && !it.first().isLowSurrogate() })
        }
    }

    @Test fun failedEngineStartupAllowsRetryAndConcurrentRepliesAreRejected() = runTest {
        var fail = true; val engine = Engine()
        val speaker = SpokenReply { if (fail) throw VoiceFailure("Missing voice") else engine }
        assertTrue(runCatching { speaker.speak("Hello") }.exceptionOrNull() is VoiceFailure)
        fail = false
        val active = launch { speaker.speak("Hello again") }; runCurrent()
        assertTrue(runCatching { speaker.speak("Overlap") }.isFailure)
        assertEquals(1, engine.chunks.size); active.cancelAndJoin(); assertEquals(1, engine.closed)
    }
}
