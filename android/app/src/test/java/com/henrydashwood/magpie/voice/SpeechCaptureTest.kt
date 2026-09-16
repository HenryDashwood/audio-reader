package com.henrydashwood.magpie.voice

import kotlinx.coroutines.*
import kotlinx.coroutines.test.*
import org.junit.Assert.*
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class SpeechCaptureTest {
    private class Engine : RecognitionEngine {
        lateinit var emit: (RecognitionEvent) -> Unit
        var stopped = 0
        var closed = 0
        override fun start(emit: (RecognitionEvent) -> Unit) { this.emit = emit }
        override fun finish() { stopped++ }
        override fun close() { closed++ }
    }

    @Test fun finalReplacesPartialAndNothingExecutesUntilItArrives() = runTest {
        val engine = Engine(); val captions = mutableListOf<String>()
        val capture = SpeechCapture { testScheduler.currentTime }
        val result = async { capture.listen(engine, onPartial = captions::add) }
        runCurrent(); engine.emit(RecognitionEvent.Ready)
        engine.emit(RecognitionEvent.Partial("Play the news")); runCurrent()
        assertFalse(result.isCompleted); assertEquals(listOf("Play the news"), captions)
        engine.emit(RecognitionEvent.Final("  Pause the news  ")); runCurrent()
        assertEquals("Pause the news", result.await()); assertEquals(1, engine.closed)
    }

    @Test fun firstWordDeadlineStartsWhenEngineIsReadyAndHonorsFollowUpPreference() = runTest {
        val engine = Engine(); val capture = SpeechCapture { testScheduler.currentTime }
        var ready = false
        val result = async { capture.listen(engine, 30_000, onReady = { ready = true }) }
        runCurrent(); advanceTimeBy(9_000); engine.emit(RecognitionEvent.Ready); runCurrent()
        assertTrue(ready)
        advanceTimeBy(29_999); runCurrent(); assertFalse(result.isCompleted)
        advanceTimeBy(1); runCurrent(); assertNull(result.await()); assertEquals(1, engine.closed)
    }

    @Test fun identicalPartialsDoNotExtendSilenceAndStillRequireAFinalResult() = runTest {
        val engine = Engine(); val capture = SpeechCapture { testScheduler.currentTime }
        val result = async { capture.listen(engine) }
        runCurrent(); engine.emit(RecognitionEvent.Ready); engine.emit(RecognitionEvent.Partial("Pause")); runCurrent()
        advanceTimeBy(2_000); engine.emit(RecognitionEvent.Partial("Pause")); runCurrent()
        advanceTimeBy(500); runCurrent(); assertEquals(1, engine.stopped); assertFalse(result.isCompleted)
        engine.emit(RecognitionEvent.Final("Play")); runCurrent()
        assertEquals("Play", result.await())
    }

    @Test fun missingFinalResultFailsRatherThanSendingThePartial() = runTest {
        val engine = Engine(); val capture = SpeechCapture { testScheduler.currentTime }
        val result = async { runCatching { capture.listen(engine) } }
        runCurrent(); engine.emit(RecognitionEvent.Ready); engine.emit(RecognitionEvent.Partial("Delete"))
        engine.emit(RecognitionEvent.End); runCurrent()
        advanceTimeBy(5_000); runCurrent()
        assertTrue(result.await().exceptionOrNull() is VoiceFailure); assertEquals(1, engine.closed)
    }

    @Test fun finishButtonRequestsFinalOnceAndNeverReusesOldCallbacks() = runTest {
        val capture = SpeechCapture { testScheduler.currentTime }; val first = Engine()
        val old = launch { capture.listen(first) }; runCurrent(); old.cancelAndJoin()
        val second = Engine(); val result = async { capture.listen(second) }; runCurrent()
        first.emit(RecognitionEvent.Final("An old command")); runCurrent(); assertFalse(result.isCompleted)
        capture.finish(); capture.finish(); runCurrent(); assertEquals(1, second.stopped)
        second.emit(RecognitionEvent.Final("A new command")); runCurrent()
        assertEquals("A new command", result.await()); assertEquals(1, first.closed); assertEquals(1, second.closed)
    }

    @Test fun permissionErrorsAndOversizedResultsReleaseTheMicrophone() = runTest {
        listOf(RecognitionEvent.Failed("Permission revoked"), RecognitionEvent.Final("x".repeat(2_001))).forEach { event ->
            val engine = Engine(); val capture = SpeechCapture { testScheduler.currentTime }
            val result = async { runCatching { capture.listen(engine) } }; runCurrent()
            engine.emit(event); runCurrent()
            assertTrue(result.await().exceptionOrNull() is VoiceFailure); assertEquals(1, engine.closed)
        }
    }

    @Test fun failedStartupAndContinuousDictationAreBounded() = runTest {
        val capture = SpeechCapture { testScheduler.currentTime }; val engine = Engine()
        val startup = async { runCatching { capture.listen(engine) } }; runCurrent()
        advanceTimeBy(10_000); runCurrent()
        assertTrue(startup.await().exceptionOrNull() is VoiceFailure); assertEquals(1, engine.closed)
        val continuous = Engine()
        val result = async { runCatching { capture.listen(continuous) } }; runCurrent()
        continuous.emit(RecognitionEvent.Ready)
        repeat(120) { index -> continuous.emit(RecognitionEvent.Partial("Words $index")); runCurrent(); advanceTimeBy(1_000) }
        runCurrent(); assertTrue(result.await().exceptionOrNull() is VoiceFailure); assertEquals(1, continuous.closed)
    }

    @Test fun secondListenCannotStealAnActiveCapture() = runTest {
        val capture = SpeechCapture { testScheduler.currentTime }; val first = Engine(); val second = Engine()
        val active = launch { capture.listen(first) }; runCurrent()
        assertTrue(runCatching { capture.listen(second) }.exceptionOrNull() is VoiceFailure)
        assertEquals(1, second.closed); assertEquals(0, first.closed)
        active.cancelAndJoin(); assertEquals(1, first.closed)
    }
}
