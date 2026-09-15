package com.henrydashwood.magpie.data

import java.io.IOException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.*
import kotlinx.coroutines.withContext
import org.junit.Assert.*
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class SavedPreparationTest {
    private class Inbox : ArticleInbox {
        val rows = mutableMapOf<String, List<PendingArticle>>()
        var fail = false
        override suspend fun pending(owner: String) = rows[owner].orEmpty()
        override suspend fun add(owner: String, article: PendingArticle) {
            if (fail) throw IOException()
            if (pending(owner).none { it.url == article.url }) rows[owner] = pending(owner) + article
        }
        override suspend fun remove(owner: String, id: String) { if (fail) throw IOException(); rows[owner] = pending(owner).filterNot { it.id == id } }
    }
    private val item = SampleLibrary().items.first { it.kind == ContentKind.Article }.copy(episodeId = 2, contentId = 7, originalUrl = "https://example.com/article")
    private inner class Repository : SavedArticleRepository {
        var fail = false
        var gate: CompletableDeferred<Unit>? = null
        val captures = mutableListOf<Pair<PendingArticle, Int>>()
        val preparations = mutableListOf<Boolean>()
        override suspend fun captureSaved(article: PendingArticle, revision: Int) {
            captures += article to revision
            withContext(NonCancellable) { gate?.await() }
            if (fail) throw IOException()
        }
        override suspend fun prepareSaved(item: LibraryItem, replace: Boolean, revision: Int): LibraryItem {
            preparations += replace
            withContext(NonCancellable) { gate?.await() }
            if (fail) throw IOException()
            return item.copy(contentId = 8)
        }
    }
    @Test fun savesLocallyBeforeSyncAndKeepsFailedLinksForRetryInOriginalOrder() = runTest {
        val inbox = Inbox(); val repo = Repository().apply { fail = true }
        val model = SavedPreparation(backgroundScope, repo, inbox)
        model.activate("alice", 1); runCurrent()
        model.add("https://example.com/one"); runCurrent()
        val first = model.state.value.pending.single()
        assertEquals(first, repo.captures.single().first); assertNotNull(model.state.value.error)
        model.add("https://example.com/two"); runCurrent()
        assertEquals(2, model.state.value.pending.size)
        repo.fail = false; model.sync(); model.sync(); runCurrent()
        assertTrue(model.state.value.pending.isEmpty()); assertTrue(inbox.pending("alice").isEmpty())
        assertEquals(listOf("https://example.com/one", "https://example.com/two"), repo.captures.takeLast(2).map { it.first.url })
        assertEquals(first.savedAt, repo.captures[2].first.savedAt)
    }
    @Test fun activationRetriesPersistedQueueWithoutImportingOtherAccounts() = runTest {
        val inbox = Inbox().apply { rows["alice"] = listOf(PendingArticle(url = "https://alice.example")) }
        val repo = Repository(); val model = SavedPreparation(backgroundScope, repo, inbox)
        model.activate("bob", 2); runCurrent(); assertTrue(repo.captures.isEmpty())
        model.activate(null, 3); runCurrent(); assertTrue(model.state.value.pending.isEmpty())
        assertTrue(runCatching { model.add("https://signedout.example") }.isFailure)
        model.activate("alice", 4); runCurrent()
        assertEquals(4, repo.captures.single().second); assertTrue(inbox.pending("alice").isEmpty())
    }
    @Test fun lateSyncDoesNotRemoveOldAccountsPendingLinkOrPublishItIntoNewAccount() = runTest {
        val inbox = Inbox().apply { rows["alice"] = listOf(PendingArticle(url = "https://alice.example")) }
        val repo = Repository().apply { gate = CompletableDeferred() }
        val model = SavedPreparation(backgroundScope, repo, inbox)
        model.activate("alice", 1); runCurrent()
        model.activate("bob", 2); runCurrent(); repo.gate!!.complete(Unit); runCurrent()
        assertEquals("bob", model.state.value.owner); assertTrue(model.state.value.pending.isEmpty())
        assertEquals(1, inbox.pending("alice").size)
    }
    @Test fun failedDiskWriteCannotReportASaveOrStartCapture() = runTest {
        val inbox = Inbox(); val repo = Repository(); val notices = mutableListOf<String>()
        val model = SavedPreparation(backgroundScope, repo, inbox, notices::add)
        model.activate("alice", 1); runCurrent(); inbox.fail = true
        assertTrue(runCatching { model.add("https://example.com") }.isFailure)
        assertTrue(notices.isEmpty()); assertTrue(repo.captures.isEmpty())
    }
    @Test fun replacementRequiresConfirmationAndFailureCanBeRetriedWithoutChangingTheCopy() = runTest {
        val repo = Repository(); val changed = mutableListOf<LibraryItem>()
        val model = SavedPreparation(backgroundScope, repo, Inbox(), changed = { _, after -> changed += after })
        model.activate("alice", 1); runCurrent()
        model.requestReplacement(item); model.cancelReplacement(); model.replace(); runCurrent(); assertTrue(repo.preparations.isEmpty())
        repo.fail = true; model.requestReplacement(item); model.replace(); runCurrent()
        assertNotNull(model.state.value.error); assertTrue(changed.isEmpty())
        repo.fail = false; model.requestReplacement(item); model.replace(); model.replace(); runCurrent()
        assertEquals(listOf(true, true), repo.preparations); assertEquals(8, changed.single().contentId)
        model.retry(item); runCurrent(); assertFalse(repo.preparations.last())
    }
    @Test fun replacementReplyAfterSignOutCannotAnnounceOrInvalidatePlayback() = runTest {
        val repo = Repository().apply { gate = CompletableDeferred() }; val notices = mutableListOf<String>()
        var changed = false
        val model = SavedPreparation(backgroundScope, repo, Inbox(), notices::add, { _, _ -> changed = true })
        model.activate("alice", 1); runCurrent(); model.requestReplacement(item); model.replace(); runCurrent()
        model.activate(null, 2); repo.gate!!.complete(Unit); runCurrent()
        assertFalse(changed); assertTrue(notices.isEmpty()); assertNull(model.state.value.replacement)
    }
}
