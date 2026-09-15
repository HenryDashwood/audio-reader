package com.henrydashwood.magpie.data

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.*
import kotlinx.coroutines.withContext
import org.junit.Assert.*
import org.junit.Test
import java.io.IOException

@OptIn(ExperimentalCoroutinesApi::class)
class SourceManagerTest {
    private val root = LibraryFeed("1", "Publication", 3, true)
    private val other = LibraryFeed("2", "Publication", 1, true)
    private val primary = FeedSource("1", "Publication", "https://public.example/feed?token=secret", "rss", primary = true)
    private val child = FeedSource("2", "Publication", "email://private@example.com", "email")
    private inner class Repository : SourceManagementRepository {
        var combined = false
        var failWrite = false
        var failLoad = false
        var gate: CompletableDeferred<Unit>? = null
        val writes = mutableListOf<Triple<String, String?, SourceChange>>()
        override suspend fun sourceGroup(feedId: String, sessionRevision: Int): SourceGroup {
            if (failLoad) throw IOException()
            return SourceGroup(if (combined) listOf(primary, child) else listOf(primary), if (combined) emptyList() else listOf(other))
        }
        override suspend fun changeSourceGroup(feedId: String, sourceId: String?, change: SourceChange, sessionRevision: Int) {
            writes += Triple(feedId, sourceId, change)
            withContext(NonCancellable) { gate?.await() }
            if (failWrite) throw IOException()
            combined = change == SourceChange.Combine
        }
    }
    @Test fun combinesAndSeparatesByIdWhilePrimaryCannotBeSeparated() = runTest {
        val repo = Repository(); val model = SourceManager(backgroundScope, repo)
        model.open(root, 1); runCurrent(); model.combine(other); runCurrent()
        assertEquals(Triple("1", "2", SourceChange.Combine), repo.writes.single())
        assertTrue(model.state.value.available.isEmpty()); assertEquals(2, model.state.value.sources.size)
        model.separate(primary); runCurrent(); assertEquals(1, repo.writes.size)
        model.separate(child); runCurrent()
        assertEquals(SourceChange.Separate, repo.writes.last().third); assertEquals(listOf(other), model.state.value.available)
    }
    @Test fun failedWritesKeepCurrentSourcesAndSuccessfulWriteWithFailedReloadCannotBeRepeated() = runTest {
        val repo = Repository(); val model = SourceManager(backgroundScope, repo)
        model.open(root, 1); runCurrent(); repo.failWrite = true; model.combine(other); runCurrent()
        assertEquals(listOf(primary), model.state.value.sources); assertNotNull(model.state.value.error)
        repo.failWrite = false; repo.failLoad = true; model.combine(other); runCurrent()
        assertEquals("Sources combined", model.state.value.notice); assertFalse(model.state.value.loaded)
        assertTrue(model.state.value.available.isEmpty()); assertNotNull(model.state.value.error)
        model.combine(other); runCurrent(); assertEquals(2, repo.writes.size)
        repo.failLoad = false; model.reload(); runCurrent(); assertEquals(2, model.state.value.sources.size)
    }
    @Test fun duplicateTapsAndLateRepliesCannotCrossAReset() = runTest {
        val repo = Repository().apply { gate = CompletableDeferred() }; val notices = mutableListOf<String>()
        val model = SourceManager(backgroundScope, repo, notices::add)
        model.open(root, 1); runCurrent(); model.combine(other); model.combine(other); runCurrent()
        assertEquals(1, repo.writes.size); assertTrue(model.state.value.busy)
        model.reset(); repo.gate!!.complete(Unit); runCurrent()
        assertFalse(model.state.value.showing); assertTrue(model.state.value.sources.isEmpty()); assertTrue(notices.isEmpty())
    }
    @Test fun unsubscribeFailureRemainsRetryableAndForwardingNoticeFollowsSuccess() = runTest {
        val repo = Repository().apply { failWrite = true }; val notices = mutableListOf<String>()
        val model = SourceManager(backgroundScope, repo, notices::add)
        model.unsubscribe(root.copy(forwarded = true), 1); runCurrent()
        assertTrue(model.state.value.showing); assertNotNull(model.state.value.error); assertTrue(notices.isEmpty())
        repo.failWrite = false; model.unsubscribe(root.copy(forwarded = true), 1); runCurrent()
        assertFalse(model.state.value.showing); assertTrue(notices.single().contains("forwarding rule"))
    }
    @Test fun sourceLocationsNeverExposePrivateFeedPathsOrTokens() {
        assertEquals("public.example", primary.location)
        assertEquals("Email newsletter", child.location)
        assertEquals("Feed", primary.copy(url = "not a URL").location)
    }
}
