package com.henrydashwood.magpie.telemetry

import kotlinx.coroutines.test.*
import kotlinx.coroutines.ExperimentalCoroutinesApi
import org.junit.Assert.*
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class AndroidExitReporterTest {
    private class Markers(var value: ExitMarker?) : ExitMarkerStore {
        override suspend fun read() = value
        override suspend fun write(marker: ExitMarker) { value = marker }
        override suspend fun clear() { value = null }
    }
    private class Store : TelemetryStore {
        var value = TelemetrySnapshot()
        override suspend fun read(owner: String) = value
        override suspend fun write(owner: String, snapshot: TelemetrySnapshot) { value = snapshot }
        override suspend fun clear() { value = TelemetrySnapshot() }
    }
    private class History(var events: List<ProcessExit>) : ExitHistory {
        var marker: String? = null
        override fun mark(nonce: String?) { marker = nonce }
        override fun recent() = events
    }
    private val session = TelemetryScope("a".repeat(64), 1, "private-credential-hash")
    private val previous = ExitMarker("abandoned-process", session.owner, session.credentialFingerprint, "old build", "old OS", 1)
    @Test fun matchingCrashUsesItsOriginalVersionAndOnlyARandomMarkerReachesTheOS() = runTest {
        val markers = Markers(previous); val history = History(listOf(ProcessExit(previous.nonce, 50, "crash", "android_java_crash")))
        val sent = mutableListOf<TelemetryEvent>()
        val queue = TelemetryQueue(Store(), { session }, { _, e -> sent += e }, this, { 100 })
        val reporter = AndroidExitReporter({ session }, { true }, queue, markers, history, { 100 }, "new build", "new OS")
        reporter.update(); runCurrent()
        assertEquals("old build", sent.single().fields["app_version"])
        assertEquals("old OS", sent.single().fields["os_version"])
        assertEquals(setOf("kind", "termination_reason", "app_version", "os_version", "window_end"), sent.single().fields.keys)
        assertEquals(markers.value!!.nonce, history.marker)
        assertTrue(history.marker!!.matches(Regex("[a-f0-9-]{36}")))
        assertFalse(history.marker!!.contains(session.owner))
        reporter.update(); runCurrent(); assertEquals(1, sent.size)
    }
    @Test fun differentAccountOrCredentialNeverReceivesAHistoricalCrash() = runTest {
        for (foreign in listOf(previous.copy(owner = "b".repeat(64)), previous.copy(credentialFingerprint = "different-session"))) {
            val queue = TelemetryQueue(Store(), { session }, { _, _ -> fail("Wrong account/session") }, this, { 100 })
            val history = History(listOf(ProcessExit(foreign.nonce, 50, "hang", "android_anr")))
            AndroidExitReporter({ session }, { true }, queue, Markers(foreign), history, { 100 }, "new", "OS").update()
            runCurrent()
        }
    }
    @Test fun signOutOrOptOutRemovesTheMarkerWithoutReadingOrUploadingHistory() = runTest {
        val markers = Markers(previous); val history = History(emptyList())
        val queue = TelemetryQueue(Store(), { null }, { _, _ -> fail("Signed out") }, this)
        AndroidExitReporter({ null }, { false }, queue, markers, history, { 100 }, "new", "OS").update()
        assertNull(markers.value); assertNull(history.marker)
    }
}
