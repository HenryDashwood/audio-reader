package com.henrydashwood.magpie.voice

import kotlinx.coroutines.*
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.test.*
import org.junit.Assert.*
import org.junit.Test
import java.io.Reader
import java.io.StringReader

@OptIn(ExperimentalCoroutinesApi::class)
class VoiceProtocolTest {
    private val receipt = VoiceResponse(VoiceAction.Unknown, "Which show?", expectsReply = true)
    @Test fun deltasAreOnlyPreviewAndAFinalReceiptIsRequired() = runTest {
        val captions = mutableListOf<String>()
        val result = VoiceExecution.response(flowOf(VoiceEvent.Delta("Which "), VoiceEvent.Delta("show?"), VoiceEvent.Result(receipt)), captions::add)
        assertEquals(receipt, result); assertEquals(listOf("Which ", "show?"), captions)
        val failure = runCatching { VoiceExecution.response(flowOf(VoiceEvent.Delta("Done."))) }.exceptionOrNull()
        assertTrue(failure is VoiceFailure); assertEquals(VoiceExecution.UNCONFIRMED, failure!!.message)
    }
    @Test fun streamErrorsAndDuplicateReceiptsNeverBecomeSuccessfulOperations() = runTest {
        val streams = listOf(
            flow { emit(VoiceEvent.Result(receipt)); throw VoiceFailure("Disconnected") },
            flowOf(VoiceEvent.Result(receipt), VoiceEvent.Result(receipt)),
            flowOf(VoiceEvent.Result(receipt), VoiceEvent.Delta("another answer")),
            flowOf(VoiceEvent.Delta("x".repeat(32_001)))
        )
        streams.forEach { assertTrue(runCatching { VoiceExecution.response(it) }.exceptionOrNull() is VoiceFailure) }
    }
    @Test fun cancellationDoesNotTurnAPreviewIntoAReceipt() = runTest {
        var completed = false
        var cancelled = false
        val job = launch {
            try {
                VoiceExecution.response(flow { emit(VoiceEvent.Delta("Working")); awaitCancellation() })
                completed = true
            } finally { cancelled = true }
        }
        runCurrent(); job.cancelAndJoin()
        assertFalse(completed); assertTrue(cancelled)
    }
    @Test fun streamingRequestHasAFiveMinuteOverallDeadline() = runTest {
        var failure: Throwable? = null
        val job = launch { failure = runCatching { VoiceExecution.response(flow { awaitCancellation() }) }.exceptionOrNull() }
        runCurrent(); advanceTimeBy(300_001); runCurrent(); job.join()
        assertTrue(failure is TimeoutCancellationException)
    }
    @Test fun framingHandlesArbitraryReadBoundariesCrLfAndFinalLineWithoutNewline() {
        val input = "\r\n{\"text\":\"hello 🐦\"}\r\n{\"type\":\"result\"}"
        val reader = object : Reader() {
            var index = 0
            override fun close() {}
            override fun read(buffer: CharArray, offset: Int, length: Int): Int {
                if (index == input.length) return -1
                buffer[offset] = input[index++]; return 1
            }
        }
        val lines = mutableListOf<String>(); VoiceLines.read(reader, lines::add)
        assertEquals(listOf("{\"text\":\"hello 🐦\"}", "{\"type\":\"result\"}"), lines)
    }
    @Test fun oversizedLinesAndStreamsAreRejectedWithoutUnboundedBuffering() {
        assertTrue(runCatching { VoiceLines.read(StringReader("x".repeat(VoiceLines.MAX_LINE + 1))) {} }.exceptionOrNull() is VoiceFailure)
        val input = ("x".repeat(99_999) + "\n").repeat(41)
        assertTrue(runCatching { VoiceLines.read(StringReader(input)) {} }.exceptionOrNull() is VoiceFailure)
    }
    @Test fun compoundEffectsDoNotApplyTheSummaryActionTwiceAndUnknownActionsRemainReadable() {
        val speed = VoiceResponse(VoiceAction.Speed, "Faster", speed = 1.5f)
        val result = receipt.copy(action = VoiceAction.Speed, actions = listOf(speed, receipt))
        assertEquals(listOf(speed, receipt), result.effects)
        assertEquals(VoiceAction.Unknown, VoiceAction.decode("future_action"))
    }
}
