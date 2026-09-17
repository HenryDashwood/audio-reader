package com.henrydashwood.magpie

import androidx.test.core.app.ApplicationProvider
import com.henrydashwood.magpie.data.*
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.util.UUID

class FileArticleProgressStoreTest {
    @Test fun journalPreservesRequestsGuardsAndAccountIsolationAcrossRecreation() = runBlocking {
        val app = ApplicationProvider.getApplicationContext<MagpieTestApplication>()
        val directory = File(app.noBackupFilesDir, "journal-test-${UUID.randomUUID()}")
        val owner = "a".repeat(64); val other = "b".repeat(64)
        try {
            val store = FileArticleProgressStore(directory)
            val row = QueuedArticleProgress(1, "new-playback", owner, ArticleProgressSample("c".repeat(64), 42, 30, true),
                ArticleProgressReport(owner, "d".repeat(64), 41, 10, false, "unchanged-request"), "old-playback", true,
                dismissed = true, guards = setOf("filing-one", "filing-two"))
            store.write(owner, listOf(row)); store.write(other, listOf(row.copy(blocked = true)))
            val fresh = FileArticleProgressStore(directory)
            assertEquals(listOf(row), fresh.read(owner)); assertEquals(listOf(row.copy(blocked = true)), fresh.read(other))
            fresh.write(owner, emptyList()); assertTrue(store.read(owner).isEmpty()); assertEquals(1, store.read(other).size)
            try { store.read("../invalid"); fail() } catch (_: IllegalArgumentException) { }
        } finally { directory.deleteRecursively() }
    }
    @Test fun corruptJournalFailsClosedWithoutDeletingFilingGuards() = runBlocking {
        val app = ApplicationProvider.getApplicationContext<MagpieTestApplication>()
        val directory = File(app.noBackupFilesDir, "journal-test-${UUID.randomUUID()}")
        val owner = "a".repeat(64)
        try {
            directory.mkdirs(); val file = File(directory, "$owner.json"); file.writeText("{broken")
            try { FileArticleProgressStore(directory).read(owner); fail() } catch (_: org.json.JSONException) { }
            assertEquals("{broken", file.readText())
        } finally { directory.deleteRecursively() }
    }
}
