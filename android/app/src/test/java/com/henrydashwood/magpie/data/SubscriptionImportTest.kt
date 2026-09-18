package com.henrydashwood.magpie.data

import com.henrydashwood.magpie.ui.readBytesBounded
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.runCurrent
import org.junit.Test
import org.junit.Assert.*
import java.io.IOException

@OptIn(ExperimentalCoroutinesApi::class)
class SubscriptionImportTest {
    private fun draft() = ImportJob("review", "draft", 1, true, 0, 0, 0, 0, 0, 0,
        listOf(ImportItem(7, "Café & 科学", "example.org", "ready", null, false, false),
            ImportItem(8, "Private", "", "invalid", "Not supported", false, false)))
    private inner class Repository : SubscriptionImportRepository {
        override var importSession: String? = "account-a"
        var job: ImportJob? = draft()
        var gate: CompletableDeferred<ImportJob>? = null
        var failStart = false
        val calls = mutableListOf<Triple<String, String?, Set<Int>?>>()
        override suspend fun currentImport() = job
        override suspend fun previewImport(bytes: ByteArray) = gate?.await() ?: draft()
        override suspend fun mutateImport(id: String, action: String, requestId: String?, entries: Set<Int>?): ImportJob {
            calls += Triple(action, requestId, entries)
            if (failStart) { failStart = false; throw IOException() }
            return draft().copy(status = if (action == "stop") "stopped" else "queued")
        }
    }
    @Test fun reviewSelectsOnlyEligibleRowsAndStartsWithoutConfirmation() = runTest {
        val repo = Repository(); val model = SubscriptionImportController(this, repo)
        model.open(); runCurrent()
        assertEquals(setOf(7), model.state.value.selected)
        model.start(); runCurrent()
        assertEquals(setOf(7), repo.calls.single().third)
        assertTrue(model.state.value.job!!.active)
    }
    @Test fun lostResponseRetainsSameRequestAndFreezesSelection() = runTest {
        val repo = Repository().apply { failStart = true }; val model = SubscriptionImportController(this, repo)
        model.open(); runCurrent(); model.start(); runCurrent()
        assertTrue(model.state.value.uncertain)
        model.select(8, true); model.chooseAnother()
        assertEquals(setOf(7), model.state.value.selected)
        model.start(); runCurrent()
        assertEquals(repo.calls[0], repo.calls[1])
        assertFalse(model.state.value.uncertain)
    }
    @Test fun accountChangeDiscardsLateFileResponse() = runTest {
        val gate = CompletableDeferred<ImportJob>()
        val repo = Repository().apply { this.gate = gate }
        val model = SubscriptionImportController(this, repo)
        model.preview(byteArrayOf(1)); runCurrent()
        repo.importSession = "account-b"
        model.invalidate(); gate.complete(draft()); runCurrent()
        assertNull(model.state.value.job)
        assertFalse(model.state.value.busy)
    }
    @Test fun dismissAndReopenRecoversAcceptedServerJob() = runTest {
        val repo = Repository(); val model = SubscriptionImportController(this, repo)
        model.open(); runCurrent(); model.close()
        repo.job = draft().copy(status = "running")
        model.open(); runCurrent()
        assertTrue(model.state.value.job!!.active)
        assertTrue(model.state.value.showing)
        assertTrue(repo.calls.isEmpty())
    }
    @Test fun boundedReaderHandlesShortReadsAndRejectsEmptyOrOversize() {
        val bytes = "<opml>科学</opml>".toByteArray()
        val stream = object : java.io.ByteArrayInputStream(bytes) {
            override fun read(buffer: ByteArray, offset: Int, length: Int) = super.read(buffer, offset, minOf(2, length))
        }
        assertArrayEquals(bytes, stream.readBytesBounded(bytes.size))
        for (input in listOf(byteArrayOf(), ByteArray(33))) {
            try { input.inputStream().readBytesBounded(32); fail("Expected size rejection") }
            catch (_: IllegalArgumentException) { }
        }
    }
}
