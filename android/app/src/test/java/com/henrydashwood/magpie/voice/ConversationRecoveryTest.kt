package com.henrydashwood.magpie.voice

import java.io.IOException
import kotlinx.coroutines.*
import kotlinx.coroutines.test.*
import org.junit.Assert.*
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class ConversationRecoveryTest {
    private class Store : ConversationStore {
        val rows = mutableMapOf<String, List<RecoverableVoiceRequest>>()
        var readGate: CompletableDeferred<Unit>? = null
        var writeGate: CompletableDeferred<Unit>? = null
        var fail = false
        override suspend fun read(owner: String): List<RecoverableVoiceRequest> {
            val snapshot = rows[owner].orEmpty(); readGate?.await(); return snapshot
        }
        override suspend fun write(owner: String, requests: List<RecoverableVoiceRequest>) {
            writeGate?.await(); if (fail) throw IOException("Disk full")
            rows[owner] = requests
        }
    }
    @Test fun originalRequestsReceiptsAndOlderUnfinishedWorkSurviveNewInstances() = runTest {
        val store = Store(); val first = Conversation(store).apply { activate("1:alice:true") }
        first.restore("alice")
        first.appSaid("Which item?")
        val old = first.request("File this", 4, 9, "GB"); first.persist("alice")
        val receipt = VoiceResponse(VoiceAction.Unknown, "Done")
        first.confirmed(old, first.owner, receipt); first.persist("alice")
        val next = first.request("Find history"); first.persist("alice")
        val restored = Conversation(store).apply { activate("7:alice:true") }
        restored.restore("alice")
        assertEquals(listOf(next, old), restored.recoveryRequests)
        restored.selectRecovery(old.requestId)
        assertEquals(old, restored.request("try again", recover = true)); assertEquals(receipt, restored.receipt)
        assertEquals("File this", restored.turns[1].text)
        restored.complete(old, restored.owner, listOf("filed"), "alice")
        assertEquals(next, restored.pending)
        assertEquals(listOf(next), store.read("alice").map { it.request })
    }
    @Test fun accountChangeWhileReadingCannotExposeTheOldJournal() = runTest {
        val store = Store().apply { rows["alice"] = listOf(RecoverableVoiceRequest(VoiceRequest("Private"))) }
        val context = Conversation(store).apply { activate("alice") }
        store.readGate = CompletableDeferred()
        val loading = launch { context.restore("alice") }; runCurrent()
        context.activate("bob"); store.readGate!!.complete(Unit); loading.join()
        assertNull(context.pending); assertTrue(context.recoveryRequests.isEmpty())
        context.restore("bob"); assertTrue(context.recoveryRequests.isEmpty())
    }
    @Test fun signoutWaitsForOlderWriteThenClearsTheJournal() = runTest {
        val store = Store(); val context = Conversation(store).apply { activate("alice") }
        context.restore("alice"); context.request("File this")
        store.writeGate = CompletableDeferred()
        val saving = launch { context.persist("alice") }; runCurrent()
        context.activate(null)
        val clearing = launch { context.clearStored("alice") }; runCurrent()
        store.writeGate!!.complete(Unit); saving.join(); clearing.join()
        assertTrue(store.read("alice").isEmpty()); assertNull(context.pending)
    }
    @Test fun failedCleanupRetainsReceiptForExplicitRecoveryWithoutRepeatingServerWork() = runTest {
        val store = Store(); val context = Conversation(store).apply { activate("alice") }
        context.restore("alice"); val request = context.request("File this")
        val receipt = VoiceResponse(VoiceAction.Unknown, "Done")
        context.confirmed(request, "alice", receipt); context.persist("alice")
        store.fail = true
        try { context.complete(request, "alice", emptyList(), "alice"); fail() } catch (_: IOException) { }
        assertEquals(receipt, context.receipt); assertEquals(request, context.pending)
        assertEquals(receipt, store.read("alice").single().receipt)
        store.fail = false; context.complete(request, "alice", emptyList(), "alice")
        assertNull(context.pending); assertTrue(store.read("alice").isEmpty())
    }
    @Test fun selectedOlderRequestSuppliesItsOwnConversationContext() = runTest {
        val context = Conversation().apply { activate("alice") }
        context.appSaid("Choose an episode")
        val old = context.request("The history one")
        context.request("Something unrelated")
        context.selectRecovery(old.requestId)
        assertEquals(listOf("Choose an episode", "The history one"), context.turns.map { it.text })
        assertSame(old, context.request("try again", recover = true))
    }
}
