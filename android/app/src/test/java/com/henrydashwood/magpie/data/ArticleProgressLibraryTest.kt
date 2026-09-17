package com.henrydashwood.magpie.data

import java.io.IOException
import java.security.MessageDigest
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.*
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class ArticleProgressLibraryTest {
    private class Store : ArticleProgressStore {
        val rows = mutableMapOf<String, List<QueuedArticleProgress>>()
        override suspend fun read(owner: String) = rows[owner].orEmpty()
        override suspend fun write(owner: String, entries: List<QueuedArticleProgress>) { rows[owner] = entries }
    }
    private class Cache : LibraryCache, AccountIdentityStore {
        var snapshot: LibrarySnapshot? = null
        val owners = mutableMapOf<String, String>()
        override suspend fun load(owner: String) = snapshot?.takeIf { it.owner == owner }
        override suspend fun save(snapshot: LibrarySnapshot) { this.snapshot = snapshot }
        override suspend fun clear(owner: String) { if (snapshot?.owner == owner) snapshot = null }
        override fun owner(sessionKey: String) = owners[sessionKey]
        override suspend fun remember(sessionKey: String, owner: String) { owners[sessionKey] = owner }
    }
    private class Api : LibraryApi, ArticleProgressApi {
        var body = "Café 🌱. A second sentence. The final passage."
        val hash get() = MessageDigest.getInstance("SHA-256").digest(body.toByteArray()).joinToString("") { "%02x".format(it) }
        var revision = "a".repeat(64)
        var row = RemoteEpisode(1, "Article", source = "Publication", contentId = 7)
        var offline = false
        var gate: CompletableDeferred<Unit>? = null
        var receipt: ArticleProgressReceipt? = null
        var textCalls = 0
        val reports = mutableListOf<ArticleProgressReport>()
        fun connected() { if (offline) throw IOException("Offline") }
        override suspend fun userId(token: String) = "reader"
        override suspend fun feeds(token: String): List<LibraryFeed> { connected(); return emptyList() }
        override suspend fun latest(token: String): List<RemoteEpisode> { connected(); return listOf(row) }
        override suspend fun saved(token: String) = latest(token)
        override suspend fun episodes(token: String, feedId: String, query: String) = latest(token)
        override suspend fun search(token: String, query: String) = latest(token)
        override suspend fun episode(token: String, episodeId: Int): RemoteEpisode { connected(); return row }
        override suspend fun text(token: String, episodeId: Int, contentId: Int?): RemoteText {
            connected(); textCalls++
            assertEquals(row.contentId, contentId)
            return RemoteText(1, row.contentId, body, null, 8,
                articleProgress = ArticleProgressState(hash, row.contentId, revision, row.articleBookmark))
        }
        override suspend fun articleProgress(token: String, episodeId: Int, report: ArticleProgressReport): ArticleProgressReceipt {
            reports += report; connected(); gate?.await()
            return receipt ?: run {
                row = row.copy(articleBookmark = RemoteArticleBookmark(report.textVersion, report.offsetUtf16), completed = report.completed)
                revision = "b".repeat(64)
                ArticleProgressReceipt(row, ArticleProgressState(hash, row.contentId, revision, row.articleBookmark), revision)
            }
        }
        override suspend fun save(token: String, episodeId: Int?, url: String?) = row
        override suspend fun remove(token: String, episodeId: Int) {}
        override suspend fun played(token: String, episodeId: Int, played: Boolean) { row = row.copy(completed = played); revision = "c".repeat(64) }
        override suspend fun clearLatest(token: String) {}
        override suspend fun subscribe(token: String, url: String) = LibraryFeed("1", "Publication", 1, true)
        override suspend fun position(token: String, episodeId: Int, seconds: Double, completed: Boolean) = error("Never report article audio seconds")
    }
    @Test fun adaptersWithoutArticleProgressKeepTheirCachedOfflinePlaybackPath() = runTest {
        val base = Api()
        val legacy = object : LibraryApi by base {
            override suspend fun episode(token: String, episodeId: Int): RemoteEpisode = error("Legacy adapter has no item lookup")
        }
        val library = AccountLibrary(legacy, "https://articles.invalid")
        library.changeSession("alice")
        val item = library.content(library.state.value.items.single().id)
        base.offline = true
        assertEquals(item, library.content(item.id, forPlayback = true))
        assertEquals(1, base.textCalls)
        assertFalse(library.usesGuardedProgress(item))
    }
    @Test fun explicitPlayRefreshesCachedBookmarkAndChangedSelectedText() = runTest {
        val api = Api(); val library = AccountLibrary(api, "https://articles.invalid", articleQueue = ArticleProgressQueue(Store()))
        library.changeSession("alice"); val id = library.state.value.items.single().id
        val first = library.content(id)
        api.row = api.row.copy(articleBookmark = RemoteArticleBookmark(api.hash, 9)); api.revision = "b".repeat(64)
        assertEquals(first, library.content(id)); assertEquals(1, api.textCalls)
        val resumed = library.content(id, forPlayback = true)
        assertEquals(9, resumed.articleBookmark!!.offsetUtf16); assertEquals(api.revision, resumed.articleProgress!!.revision)
        api.body = "A replacement 🦉 article."; api.row = api.row.copy(contentId = 8, articleBookmark = null)
        val replacement = library.content(id, forPlayback = true)
        assertEquals(api.hash, replacement.contentVersion); assertEquals(8, replacement.contentId)
        assertNull(replacement.articleBookmark); assertNotEquals(first.text, replacement.text)
    }
    @Test fun offlineRestartRestoresMatchingPendingBookmarkWithoutCreatingANewRequest() = runTest {
        val api = Api(); val store = Store(); val cache = Cache()
        fun fresh() = AccountLibrary(api, "https://articles.invalid", identityStore = cache, cache = cache, articleQueue = ArticleProgressQueue(store))
        val library = fresh(); library.changeSession("alice")
        val item = library.content(library.state.value.items.single().id, forPlayback = true)
        library.beginArticleProgress(item, "play", 0); library.recordArticleProgress(item, "play", 9, false)
        val request = store.rows.values.single().single().pending
        api.offline = true
        val reopened = fresh(); reopened.changeSession("alice")
        val restored = reopened.content(item.id, forPlayback = true)
        assertEquals(9, restored.articleBookmark!!.offsetUtf16); assertEquals(item.contentVersion, restored.contentVersion)
        assertEquals(request, store.rows.values.single().single().pending)
        api.offline = false; reopened.flushArticleProgress()
        assertEquals(listOf(request), api.reports); assertNull(store.rows.values.single().single().pending)
        assertEquals(9, reopened.state.value.items.single().articleBookmark!!.offsetUtf16)
        reopened.changeSession(null); assertTrue(store.rows.values.single().isEmpty()); assertNull(cache.snapshot)
    }
    @Test fun acknowledgementKeepsSamplesRecordedDuringNetworkWaitAndNewerFilingBlocksThem() = runTest {
        val api = Api(); val store = Store(); val library = AccountLibrary(api, "https://articles.invalid", articleQueue = ArticleProgressQueue(store))
        library.changeSession("alice"); val item = library.content(library.state.value.items.single().id)
        library.beginArticleProgress(item, "play", 0); library.recordArticleProgress(item, "play", 9, false)
        api.gate = CompletableDeferred()
        val sending = launch { library.flushArticleProgress() }; runCurrent()
        library.recordArticleProgress(item, "play", 20, false)
        api.gate!!.complete(Unit); sending.join()
        assertEquals(20, library.state.value.items.single().articleBookmark!!.offsetUtf16)
        assertEquals("b".repeat(64), store.rows.values.single().single().pending!!.expectedRevision)
        val filed = api.row.copy(completed = true, articleBookmark = null)
        api.receipt = ArticleProgressReceipt(filed, ArticleProgressState(api.hash, 7, "c".repeat(64), null), "b".repeat(64))
        library.flushArticleProgress(); assertTrue(library.state.value.items.single().completed)
        assertFalse(library.recordArticleProgress(item, "play", 30, false)); assertTrue(store.rows.values.single().single().blocked)
    }
    @Test fun manualFilingRetiresQueuedArticleWritesBeforeSendingMutation() = runTest {
        val api = Api(); val store = Store(); val library = AccountLibrary(api, "https://articles.invalid", articleQueue = ArticleProgressQueue(store))
        library.changeSession("alice"); val item = library.content(library.state.value.items.single().id)
        library.beginArticleProgress(item, "play", 0); library.recordArticleProgress(item, "play", 9, false)
        library.played(item, true)
        library.flushArticleProgress(); assertTrue(api.reports.isEmpty()); assertTrue(api.row.completed)
        assertFalse(library.recordArticleProgress(item, "play", 20, false))
    }
}
