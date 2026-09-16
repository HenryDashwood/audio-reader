package com.henrydashwood.magpie.data

import com.henrydashwood.magpie.voice.*
import kotlinx.coroutines.*
import kotlinx.coroutines.test.*
import org.junit.Assert.*
import org.junit.Test
import java.io.IOException

@OptIn(ExperimentalCoroutinesApi::class)
class LibraryActionExecutionTest {
    private val receipt = VoiceResponse(VoiceAction.Played, "Marked as played", RemoteEpisode(1, "Episode", completed = true))

    @Test fun uncertainRetryKeepsTheRequestIdAndSuccessfulRepeatStartsANewAction() = runTest {
        val execution = LibraryActionExecution { "one" }
        val ids = mutableListOf<String>()
        assertTrue(runCatching { execution.run("mark_played", 1, {}, { ids += it; throw IOException() }, {}) }.isFailure)
        execution.run("mark_played", 1, {}, { ids += it; receipt }, {})
        execution.run("mark_played", 1, {}, { ids += it; receipt }, {})
        assertEquals(ids[0], ids[1]); assertNotEquals(ids[1], ids[2])
    }
    @Test fun receiptSurvivesCancelledReconciliationWithoutRepeatingTheServerMutation() = runTest {
        val execution = LibraryActionExecution { "one" }
        var sent = 0
        assertTrue(runCatching { execution.run("mark_played", 1, {}, { sent++; receipt }, { throw CancellationException() }) }.isFailure)
        var applied: VoiceResponse? = null
        execution.run("mark_played", 1, {}, { error("Must reuse receipt") }, { applied = it })
        assertEquals(1, sent); assertEquals(receipt, applied)
    }
    @Test fun anUncertainCurrentItemRemainsTheRetryTargetUntilSuccessOrAccountChange() = runTest {
        var owner = "one"
        val execution = LibraryActionExecution { owner }
        assertTrue(runCatching { execution.run("mark_played", 1, {}, { throw IOException() }, {}, useCurrent = true) }.isFailure)
        assertEquals(1, execution.pendingCurrentItem("mark_played")); assertNull(execution.pendingCurrentItem("dismiss"))
        owner = "two"; assertNull(execution.pendingCurrentItem("mark_played"))
        execution.invalidate(); owner = "one"; assertNull(execution.pendingCurrentItem("mark_played"))
    }
    @Test fun anExplicitNewChangeCanReplaceAnUnconfirmedRequestWithoutAutomaticallyRepeatingIt() = runTest {
        val execution = LibraryActionExecution { "one" }
        var original: String? = null
        assertTrue(runCatching { execution.run("mark_played", 1, {}, { original = it; throw IOException() }, {}) }.isFailure)
        execution.run("mark_played", 1, {}, { assertNotEquals(original, it); receipt }, {}, startNewChange = true)
    }
    @Test fun overlappingCallsAreRejectedBeforeTheyCanPauseThePlayer() = runTest {
        val execution = LibraryActionExecution { "one" }
        val gate = CompletableDeferred<Unit>()
        val first = launch { execution.run("mark_played", 1, {}, { gate.await(); receipt }, {}) }
        runCurrent()
        var interrupted = false
        assertTrue(runCatching { execution.run("dismiss", 1, { interrupted = true }, { error("No request") }, {}) }.isFailure)
        assertFalse(interrupted); gate.complete(Unit); first.join()
    }
    @Test fun accountSwitchRejectsTheOldReceiptWithoutBlockingOrClearingTheNewAccountsRetry() = runTest {
        var owner = "one"
        val execution = LibraryActionExecution { owner }
        val gate = CompletableDeferred<Unit>()
        var oldApplied = false
        val old = async { runCatching { execution.run("mark_played", 1, {}, { gate.await(); receipt }, { oldApplied = true }) } }
        runCurrent(); owner = "two"; execution.invalidate()
        var newId: String? = null
        assertTrue(runCatching { execution.run("mark_played", 1, {}, { newId = it; throw IOException() }, {}) }.isFailure)
        gate.complete(Unit); assertTrue(old.await().exceptionOrNull() is CancellationException); assertFalse(oldApplied)
        execution.run("mark_played", 1, {}, { assertEquals(newId, it); receipt }, {})
    }
    @Test fun invalidAndSignedOutActionsDoNoPreparationOrNetworkWork() = runTest {
        for ((action, id) in listOf("invalid" to 1, "mark_played" to null, "undo" to 1, "dismiss" to -1)) {
            var began = false
            assertTrue(runCatching { LibraryActionExecution { "one" }.run(action, id, { began = true }, { error("Network") }, {}) }.isFailure)
            assertFalse(began)
        }
        var began = false
        assertTrue(runCatching { LibraryActionExecution { null }.run("undo", null, { began = true }, { error("Network") }, {}) }.isFailure)
        assertFalse(began)
    }
    @Test fun mismatchedReceiptsAreNeverAppliedAndEmptyUndoIsAnHonestNoChange() = runTest {
        val execution = LibraryActionExecution { "one" }
        var applied = false
        assertTrue(runCatching { execution.run("mark_played", 2, {}, { receipt }, { applied = true }) }.isFailure)
        assertFalse(applied)
        val unavailable = VoiceResponse(VoiceAction.Unknown, "There is no recent action to undo.")
        assertEquals(unavailable, execution.run("undo", null, {}, { unavailable }, {}))
    }
}
