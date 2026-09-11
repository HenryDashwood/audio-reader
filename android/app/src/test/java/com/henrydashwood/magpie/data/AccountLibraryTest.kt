package com.henrydashwood.magpie.data

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.*
import org.junit.Test
import java.io.IOException

@OptIn(ExperimentalCoroutinesApi::class)
class AccountLibraryTest {
    private class Api : LibraryApi {
        var fail = false
        var gate: CompletableDeferred<Unit>? = null
        var oldSearch: CompletableDeferred<Unit>? = null
        var contentId = 7
        var requestedContent: Int? = null
        var saves = 0
        var positions = 0
        var texts = 0
        var latestRows = listOf(RemoteEpisode(1, "Episode", source = "Same title", feedUrl = "https://one.example/feed", audioUrl = "https://one.example/audio.mp3", positionSeconds = 42.5))
        var savedRows = listOf(RemoteEpisode(2, "Saved article", contentId = 7))
        override suspend fun userId(token: String) = token
        override suspend fun feeds(token: String): List<LibraryFeed> {
            gate?.await()
            if (fail) throw IOException()
            return listOf(LibraryFeed("1", "Same title", 80, false, "https://one.example/feed"), LibraryFeed("2", "Same title", 0, true))
        }
        override suspend fun latest(token: String) = latestRows
        override suspend fun saved(token: String) = savedRows
        override suspend fun episodes(token: String, feedId: String, query: String) = latestRows
        override suspend fun search(token: String, query: String): List<RemoteEpisode> {
            if (query == "old") oldSearch?.await()
            return listOf(RemoteEpisode(if (query == "old") 10 else 11, query))
        }
        override suspend fun text(token: String, episodeId: Int, contentId: Int?): RemoteText {
            texts++; requestedContent = contentId
            return RemoteText(episodeId, this.contentId, "Full saved text", "<p>Full saved text</p>", 3)
        }
        override suspend fun save(token: String, episodeId: Int?, url: String?): RemoteEpisode {
            saves++; if (fail) throw IOException(); return savedRows.first()
        }
        override suspend fun remove(token: String, episodeId: Int) { if (fail) throw IOException() }
        override suspend fun played(token: String, episodeId: Int, played: Boolean) { if (fail) throw IOException() }
        override suspend fun clearLatest(token: String) {}
        override suspend fun subscribe(token: String, url: String) = LibraryFeed("3", "New feed", 0, true, url)
        override suspend fun position(token: String, episodeId: Int, seconds: Double, completed: Boolean) { positions++ }
    }
    @Test fun loadsDistinctFeedsLatestAndSavedIncludingEmptyFeeds() = runTest {
        val api = Api(); val library = AccountLibrary(api, "https://staging.example")
        library.changeSession("alice")
        val state = library.state.value
        assertTrue(state.live)
        assertEquals(listOf("1", "2"), state.feeds.map { it.id })
        assertEquals(2, state.items.size)
        assertEquals(1, state.savedIds.size)
        assertEquals(42_500, state.items.first { it.episodeId == 1 }.remotePositionMs)
        assertFalse(state.items.any { it.id == "walking" })
        assertEquals(0, api.texts) // Full articles are fetched on demand.
    }
    @Test fun failedLoadNeverShowsSamplesAndRefreshFailureKeepsTheCurrentAccount() = runTest {
        val api = Api().apply { fail = true }; val library = AccountLibrary(api, "server")
        library.changeSession("alice")
        assertTrue(library.state.value.live)
        assertTrue(library.state.value.items.isEmpty())
        assertNotNull(library.state.value.error)
        api.fail = false; library.refresh()
        val items = library.state.value.items
        api.fail = true; library.refresh()
        assertEquals(items, library.state.value.items)
        assertNotNull(library.state.value.error)
    }
    @Test fun lateAccountReplyCannotRestoreTheSignedOutLibrary() = runTest {
        val api = Api().apply { gate = CompletableDeferred() }; val library = AccountLibrary(api, "server")
        val loading = launch { library.changeSession("alice") }; runCurrent()
        library.changeSession(null)
        api.gate!!.complete(Unit); loading.join()
        assertFalse(library.state.value.live)
        assertTrue(library.state.value.items.any { it.id == "walking" })
        assertNull(library.state.value.owner)
    }
    @Test fun accountsAndServersUseSeparateItemAndBookmarkNamespaces() = runTest {
        val api = Api(); val library = AccountLibrary(api, "one")
        library.changeSession("alice"); val alice = library.state.value.items.first()
        library.changeSession("bob")
        assertNotEquals(alice.id, library.state.value.items.first().id)
        assertTrue(runCatching { library.save(alice) }.isFailure)
        assertEquals(0, api.saves)
        val other = AccountLibrary(api, "two"); other.changeSession("alice")
        assertNotEquals(alice.id, other.state.value.items.first().id)
    }
    @Test fun articleReadsPinTheSavedVersionAndRejectAnUnexpectedVersion() = runTest {
        val api = Api(); val library = AccountLibrary(api, "server"); library.changeSession("alice")
        val item = library.state.value.items.first { it.episodeId == 2 }
        api.contentId = 9
        assertTrue(runCatching { library.content(item.id) }.isFailure)
        assertFalse(library.state.value.items.first { it.id == item.id }.textLoaded)
        api.contentId = 7
        val loaded = library.content(item.id)
        assertEquals(7, api.requestedContent)
        assertTrue(loaded.textLoaded)
        assertEquals("Full saved text", loaded.text)
        assertNotEquals(item.contentVersion, loaded.contentVersion)
    }
    @Test fun failedWritesDoNotPretendTheLibraryChanged() = runTest {
        val api = Api(); val library = AccountLibrary(api, "server"); library.changeSession("alice")
        val item = library.state.value.items.first { it.episodeId == 2 }
        api.fail = true
        assertTrue(runCatching { library.remove(item) }.isFailure)
        assertTrue(item.id in library.state.value.savedIds)
        assertTrue(runCatching { library.played(item, true) }.isFailure)
        assertFalse(library.state.value.items.first { it.id == item.id }.completed)
    }
    @Test fun clearLatestPreservesSavedItemsAndDoesNotMarkThemPlayed() = runTest {
        val library = AccountLibrary(Api(), "server"); library.changeSession("alice")
        val saved = library.state.value.savedIds
        library.clearLatest()
        assertTrue(library.state.value.latestIds.isEmpty())
        assertEquals(saved, library.state.value.savedIds)
        assertTrue(library.state.value.items.none { it.completed })
    }
    @Test fun olderSearchResultsCannotReplaceTheNewQuery() = runTest {
        val api = Api().apply { oldSearch = CompletableDeferred() }; val library = AccountLibrary(api, "server")
        library.changeSession("alice")
        val old = launch { library.search(null, "old") }; runCurrent()
        library.search(null, "new")
        val results = library.state.value.searchResults
        api.oldSearch!!.complete(Unit); old.join()
        assertEquals(results, library.state.value.searchResults)
        assertTrue(results.single().endsWith(":11"))
    }
    @Test fun renderedArticleSecondsCanNeverReachThePositionEndpoint() = runTest {
        val api = Api(); val library = AccountLibrary(api, "server"); library.changeSession("alice")
        assertTrue(runCatching { library.reportPodcast(library.state.value.items.first { it.episodeId == 2 }, 20.0, false) }.isFailure)
        assertEquals(0, api.positions)
        library.reportPodcast(library.state.value.items.first { it.episodeId == 1 }, 42.5, false)
        assertEquals(1, api.positions)
    }
}
