package com.henrydashwood.magpie.telemetry

import kotlinx.coroutines.*
import kotlinx.coroutines.test.*
import org.junit.Assert.*
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class TelemetryQueueTest {
    private class Store : TelemetryStore {
        val rows = mutableMapOf<String, TelemetrySnapshot>()
        var readGate: CompletableDeferred<Unit>? = null
        override suspend fun read(owner: String): TelemetrySnapshot { readGate?.await(); return rows[owner] ?: TelemetrySnapshot() }
        override suspend fun write(owner: String, snapshot: TelemetrySnapshot) { rows[owner] = snapshot }
        override suspend fun clear() { rows.clear() }
    }
    private val first = TelemetryScope("a".repeat(64), 1, "credential-a")
    private fun event(id: String = "attempt") = TelemetryEvent("voice", mapOf("outcome" to "error"), id = id, createdAt = 100)
    @Test fun offlineQueueSurvivesFreshReporterAndAcknowledgesOnlyTheDeliveredEvent() = runTest {
        val store = Store(); val sent = mutableListOf<TelemetryEvent>()
        val offline = TelemetryQueue(store, { first }, { _, _ -> throw java.io.IOException("Offline") }, this, { 100 })
        offline.record(event()); runCurrent()
        assertEquals(listOf(event()), store.rows[first.owner]!!.pending)
        val online = TelemetryQueue(store, { first }, { _, e -> sent += e }, this, { 100 })
        online.flush(); runCurrent()
        assertEquals(listOf(event()), sent); assertTrue(store.rows[first.owner]!!.pending.isEmpty())
        online.record(event()); runCurrent()
        assertEquals(1, sent.size)
    }
    @Test fun sessionChangeDuringDiskReadDiscardsLateEnqueue() = runTest {
        var current: TelemetryScope? = first
        val store = Store().apply { readGate = CompletableDeferred() }
        val queue = TelemetryQueue(store, { current }, { _, _ -> fail("Must not send") }, this, { 100 })
        queue.record(event()); runCurrent()
        current = first.copy(owner = "b".repeat(64), revision = 2)
        store.readGate!!.complete(Unit); runCurrent()
        assertTrue(store.rows.isEmpty())
    }
    @Test fun oldInFlightReplyCannotRemoveAnotherAccountsRecords() = runTest {
        var current: TelemetryScope? = first
        val store = Store(); val gate = CompletableDeferred<Unit>(); val owners = mutableListOf<String>()
        val queue = TelemetryQueue(store, { current }, { session, _ -> owners += session.owner; gate.await() }, this, { 100 })
        queue.record(event()); runCurrent()
        current = first.copy(owner = "b".repeat(64), revision = 2)
        queue.invalidate(); queue.record(event("second")); runCurrent()
        gate.complete(Unit); runCurrent()
        assertEquals(listOf(first.owner, current.owner), owners)
        assertEquals("attempt", store.rows[first.owner]!!.pending.single().id)
        assertTrue(store.rows[current.owner]!!.pending.isEmpty())
    }
    @Test fun storageIsBoundedAndExpiredOrFutureEventsAreDiscarded() = runTest {
        val store = Store()
        val queue = TelemetryQueue(store, { first }, { _, _ -> throw java.io.IOException() }, this, { 100 })
        repeat(70) { queue.record(event("event-$it")) }
        runCurrent()
        assertEquals(50, store.rows[first.owner]!!.pending.size)
        assertEquals("event-20", store.rows[first.owner]!!.pending.first().id)
        val expired = TelemetryQueue(store, { first }, { _, _ -> fail("Expired") }, this, { 31L * 86_400_000 })
        expired.flush(); runCurrent(); assertTrue(store.rows[first.owner]!!.pending.isEmpty())
    }
    @Test fun signOutOrOptOutClearsTheQueueAndRejectsLateRecords() = runTest {
        var current: TelemetryScope? = first
        val store = Store()
        val queue = TelemetryQueue(store, { current }, { _, _ -> throw java.io.IOException() }, this, { 100 })
        queue.record(event()); runCurrent(); assertFalse(store.rows.isEmpty())
        current = null; queue.clear()
        queue.record(event("late"), first); runCurrent()
        assertTrue(store.rows.isEmpty())
    }
    @Test fun unexpectedPayloadFieldsAndMalformedTraceHeadersAreRejected() {
        assertThrows(IllegalArgumentException::class.java) { TelemetryEvent("voice", mapOf("transcript" to "private words")) }
        assertThrows(IllegalArgumentException::class.java) { TelemetryEvent("diagnostic", mapOf("stack_trace" to "secret")) }
        assertThrows(IllegalArgumentException::class.java) { TelemetryEvent("voice", emptyMap(), "bad\r\nheader") }
    }
}
