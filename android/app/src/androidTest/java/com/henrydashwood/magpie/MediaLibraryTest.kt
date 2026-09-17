package com.henrydashwood.magpie

import android.content.ComponentName
import android.content.Intent
import android.media.browse.MediaBrowser as PlatformBrowser
import android.media.session.MediaController as PlatformController
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.media3.common.MediaItem
import androidx.media3.common.Player
import androidx.media3.session.*
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import androidx.test.platform.app.InstrumentationRegistry
import com.google.common.util.concurrent.ListenableFuture
import com.henrydashwood.magpie.data.*
import com.henrydashwood.magpie.playback.*
import kotlinx.coroutines.*
import org.junit.*
import org.junit.Assert.*
import java.util.concurrent.CompletableFuture
import java.util.concurrent.TimeUnit

@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
class MediaLibraryTest {
    @get:Rule val compose = createEmptyComposeRule()
    private val app get() = ApplicationProvider.getApplicationContext<MagpieTestApplication>()
    private lateinit var api: Api
    private lateinit var library: AccountLibrary
    private lateinit var browser: MediaBrowser
    private lateinit var observer: MediaController
    private var platform: PlatformBrowser? = null
    private var scenario: ActivityScenario<MainActivity>? = null
    private var searchCount: Int? = null
    private val changedFolders = mutableMapOf<String, Int>()
    private val owner get() = checkNotNull(library.state.value.owner)
    private fun id(number: Int) = "$owner:episode:$number"
    private class Api : LibraryApi {
        val first = RemoteEpisode(1, "First library podcast", source = "Library show", feedUrl = "https://fixture.invalid/feed",
            audioUrl = "asset:///welcome.wav", positionSeconds = 12.0, durationSeconds = 120)
        val second = first.copy(id = 2, title = "Second library podcast", positionSeconds = 18.0)
        val article = RemoteEpisode(3, "Library reading", source = "Writing", contentId = 30)
        var searchGate: CompletableDeferred<Unit>? = null
        var searches = 0
        var texts = 0
        var episodes = 0
        override suspend fun userId(token: String) = "media-user-$token"
        override suspend fun feeds(token: String) = listOf(LibraryFeed("10", "Library show", 2, false, "https://fixture.invalid/feed"))
        override suspend fun latest(token: String) = listOf(first, second)
        override suspend fun saved(token: String) = listOf(article)
        override suspend fun episodes(token: String, feedId: String, query: String) = listOf(second, first)
        override suspend fun search(token: String, query: String): List<RemoteEpisode> {
            searches++; searchGate?.await()
            return if (query == "missing") emptyList() else listOf(second, first)
        }
        override suspend fun episode(token: String, episodeId: Int): RemoteEpisode {
            episodes++
            return listOf(first, second, article).first { it.id == episodeId }
        }
        override suspend fun text(token: String, episodeId: Int, contentId: Int?): RemoteText {
            texts++
            return RemoteText(3, 30, "A quiet morning leaves room to listen. The trees are full of birds. We follow the path beside the garden and enjoy the day.", null, 26)
        }
        override suspend fun save(token: String, episodeId: Int?, url: String?) = article
        override suspend fun remove(token: String, episodeId: Int) {}
        override suspend fun played(token: String, episodeId: Int, played: Boolean) {}
        override suspend fun clearLatest(token: String) {}
        override suspend fun subscribe(token: String, url: String) = feeds(token).first()
        override suspend fun position(token: String, episodeId: Int, seconds: Double, completed: Boolean) { assertNotEquals(3, episodeId) }
    }
    private fun <T> main(block: () -> T): T = compose.runOnUiThread(block)
    private fun <T> await(future: ListenableFuture<T>): T = future.get(15, TimeUnit.SECONDS)
    private fun waitFor(timeout: Long = 15_000, condition: () -> Boolean) = compose.waitUntil(timeout) { main(condition) }
    private fun token() = SessionToken(app, ComponentName(app, PlaybackService::class.java))
    private fun request(number: Int) = MediaItem.Builder().setMediaId(id(number)).build()
    private fun query(text: String) = MediaItem.Builder().setRequestMetadata(MediaItem.RequestMetadata.Builder().setSearchQuery(text).build()).build()
    private fun prepared(number: Int) = waitFor { observer.currentMediaItem?.mediaId == id(number) && observer.playbackState == Player.STATE_READY }
    private fun playing(number: Int) = waitFor { observer.currentMediaItem?.mediaId == id(number) && observer.isPlaying }
    @Suppress("DEPRECATION") // Android still exposes this app's own service lifecycle to its tests.
    private fun stopService() {
        app.stopService(Intent(app, PlaybackService::class.java))
        compose.waitUntil(15_000) {
            app.getSystemService(android.app.ActivityManager::class.java).getRunningServices(Int.MAX_VALUE)
                .none { it.service.className == PlaybackService::class.java.name }
        }
    }
    @Before fun prepare() {
        stopService()
        api = Api(); library = AccountLibrary(api, "https://media-library-fixture.invalid")
        runBlocking(Dispatchers.Main) { library.changeSession("one") }
        app.libraryOverride = library
        scenario = ActivityScenario.launch(MainActivity::class.java)
        browser = await(main { MediaBrowser.Builder(app, token()).setListener(object : MediaBrowser.Listener {
            override fun onSearchResultChanged(browser: MediaBrowser, query: String, itemCount: Int, params: MediaLibraryService.LibraryParams?) { searchCount = itemCount }
            override fun onChildrenChanged(browser: MediaBrowser, parentId: String, itemCount: Int, params: MediaLibraryService.LibraryParams?) { changedFolders[parentId] = itemCount }
        }).buildAsync() })
        observer = await(main { MediaController.Builder(app, token()).buildAsync() })
    }
    @After fun finish() {
        api.searchGate?.complete(Unit)
        // Wait for the service to close before disconnecting its controllers. A
        // queued Pause can otherwise be dropped and leave a foreground service
        // restarting with the previous test's repository.
        val dismissed = await(main { observer.sendCustomCommand(
            androidx.media3.session.SessionCommand(PlaybackService.DISMISS_PLAYER, android.os.Bundle.EMPTY), android.os.Bundle.EMPTY) })
        assertEquals(0, dismissed.resultCode)
        waitFor { observer.currentMediaItem == null }
        main { platform?.disconnect(); browser.release(); observer.release() }
        scenario?.close(); stopService(); app.libraryOverride = null
    }
    private fun legacy(): PlatformController {
        val connected = CompletableFuture<PlatformController>()
        main {
            platform = PlatformBrowser(app, ComponentName(app, PlaybackService::class.java), object : PlatformBrowser.ConnectionCallback() {
                override fun onConnected() { connected.complete(PlatformController(app, platform!!.sessionToken)) }
                override fun onConnectionFailed() { connected.completeExceptionally(IllegalStateException("Legacy browser rejected")) }
            }, null).also { it.connect() }
        }
        return connected.get(15, TimeUnit.SECONDS)
    }

    @Test fun browsersSeeScopedFoldersAndPaginatedMetadataWithoutPlaybackUris() {
        val root = await(main { browser.getLibraryRoot(null) }); assertEquals(0, root.resultCode)
        val folders = await(main { browser.getChildren(root.value!!.mediaId, 0, 10, null) }).value!!
        assertEquals(listOf("Latest", "Saved", "Following"), folders.map { it.mediaMetadata.title.toString() })
        val latest = folders.first().mediaId
        assertTrue(latest.contains(owner))
        val page = await(main { browser.getChildren(latest, 1, 1, null) }).value!!
        assertEquals(id(2), page.single().mediaId); assertNull(page.single().localConfiguration)
        assertEquals(120_000L, page.single().mediaMetadata.durationMs)
        assertTrue(await(main { browser.getChildren(latest, Int.MAX_VALUE, 100, null) }).value!!.isEmpty())
        val shows = await(main { browser.getChildren(folders[2].mediaId, 0, 10, null) }).value!!
        assertEquals("Library show", shows.single().mediaMetadata.title)
        assertEquals(id(2), await(main { browser.getChildren(shows.single().mediaId, 0, 10, null) }).value!!.first().mediaId)
        assertEquals(id(3), await(main { browser.getChildren(folders[1].mediaId, 0, 10, null) }).value!!.single().mediaId)
        assertEquals(0, api.texts); assertFalse(main { observer.isPlaying })
    }

    @Test fun searchNotifiesResultsWithoutReplacingTheAppsSearch() {
        runBlocking(Dispatchers.Main) { library.search(null, "existing") }
        val old = library.state.value.searchResults
        assertEquals(0, await(main { browser.search("podcast", null) }).resultCode)
        waitFor { searchCount == 2 }
        val result = await(main { browser.getSearchResult("podcast", 0, 1, null) })
        assertEquals(id(2), result.value!!.single().mediaId)
        assertEquals(old, library.state.value.searchResults)
        assertTrue(await(main { browser.getSearchResult("missing", 0, 10, null) }).value!!.isEmpty())
        assertFalse(main { observer.isPlaying })
    }

    @Test fun prepareResolvesBookmarkWithoutStartingUntilPlay() {
        main { browser.setMediaItem(request(1)); browser.prepare() }
        prepared(1); assertFalse(main { observer.isPlaying }); assertEquals(12_000L, main { observer.currentPosition })
        main { browser.play() }; playing(1)
        main { browser.pause(); browser.seekTo(30_000) }
        waitFor { observer.currentPosition == 30_000L }
        main { browser.setMediaItem(request(1)); browser.prepare() }
        prepared(1); assertEquals(30_000L, main { observer.currentPosition }); assertFalse(main { observer.isPlaying })
    }

    @Test fun legacyAssistantCanPrepareSearchThenPlayAndPlayAnExplicitItem() {
        val controls = legacy().transportControls
        main { controls.prepareFromSearch("Library show", null) }
        prepared(2); assertFalse(main { observer.isPlaying })
        main { controls.play() }; playing(2)
        main { controls.playFromMediaId(id(1), null) }; playing(1)
        assertTrue(main { observer.currentPosition >= 12_000 })
    }

    @Test fun modernSearchAndEmptySearchUseTheSameServicePlayer() {
        main { browser.setMediaItem(query("podcast")); browser.prepare(); browser.play() }; playing(2)
        main { browser.setMediaItem(query("")); browser.prepare(); browser.play() }; playing(1)
    }

    @Test fun externalUrisAndOldAccountIdsNeverEnterThePlayer() {
        main { browser.setMediaItem(MediaItem.fromUri("file:///data/data/${app.packageName}/secret.wav")); browser.prepare() }
        waitFor { PlaybackStatus.state.value.error != null }
        assertNull(main { observer.currentMediaItem }); assertEquals(0, api.episodes)
        val old = id(1)
        runBlocking(Dispatchers.Main) { library.changeSession("two") }
        main { browser.setMediaItem(MediaItem.Builder().setMediaId(old).build()); browser.prepare() }
        waitFor { PlaybackStatus.state.value.error?.contains("another account") == true }
        assertNull(main { observer.currentMediaItem }); assertEquals(0, api.episodes)
    }

    @Test fun legacyPauseCancelsPendingSearchAndCannotStartLater() {
        val controls = legacy().transportControls
        main { controls.playFromMediaId(id(1), null) }; playing(1)
        api.searchGate = CompletableDeferred()
        main { controls.playFromSearch("podcast", null) }
        waitFor { api.searches == 1 }
        main { controls.pause() }
        waitFor { PlaybackStatus.state.value.message == null }
        api.searchGate!!.complete(Unit)
        waitFor { !observer.isPlaying }
        assertEquals(id(1), main { observer.currentMediaItem?.mediaId })
    }

    @Test fun aSecondControllerCanCancelModernPreparationWithPause() {
        main { browser.setMediaItem(request(1)); browser.prepare(); browser.play() }; playing(1)
        api.searchGate = CompletableDeferred()
        main { browser.setMediaItem(query("podcast")); browser.prepare(); browser.play() }
        waitFor { api.searches == 1 }
        waitFor { !observer.isPlaying }
        main { observer.pause() }
        waitFor { PlaybackStatus.state.value.message == null }
        api.searchGate!!.complete(Unit)
        await(main { browser.getLibraryRoot(null) })
        compose.waitForIdle()
        assertFalse(main { observer.isPlaying })
        assertEquals(id(1), main { observer.currentMediaItem?.mediaId })
        main { browser.play() }; playing(1) // A subsequent explicit Play still works.
    }

    @Test fun disconnectingTheModernRequesterCancelsItsPendingPreparation() {
        main { browser.setMediaItem(request(1)); browser.prepare(); browser.play() }; playing(1)
        api.searchGate = CompletableDeferred()
        main { browser.setMediaItem(query("podcast")); browser.prepare(); browser.play() }
        waitFor { api.searches == 1 }
        main { browser.release() }
        waitFor { PlaybackStatus.state.value.message == null }
        api.searchGate!!.complete(Unit)
        compose.waitForIdle()
        assertFalse(main { observer.isPlaying })
        assertEquals(id(1), main { observer.currentMediaItem?.mediaId })
    }

    @Test fun failedPreparationCannotPlayThePreviouslyLoadedItem() {
        main { browser.setMediaItem(request(1)); browser.prepare(); browser.play() }; playing(1)
        main { browser.setMediaItem(query("missing")); browser.prepare(); browser.play() }
        waitFor { PlaybackStatus.state.value.error != null }
        await(main { browser.getLibraryRoot(null) }); compose.waitForIdle()
        assertFalse(main { observer.isPlaying })
        assertEquals(id(1), main { observer.currentMediaItem?.mediaId })
        main { browser.play() }; playing(1)
    }

    @Test fun accountChangeDuringSearchDiscardsTheLateBrowseAndPlaybackResults() {
        api.searchGate = CompletableDeferred()
        val lookup = main { browser.getSearchResult("podcast", 0, 10, null) }
        waitFor { api.searches == 1 }
        val change = CoroutineScope(Dispatchers.Main).launch { library.changeSession("two") }
        waitFor { library.state.value.revision == 2 }
        api.searchGate!!.complete(Unit); runBlocking { change.join() }
        assertTrue(runCatching { await(lookup) }.getOrNull()?.resultCode != 0)
        assertFalse(main { observer.isPlaying })
        assertTrue(library.state.value.items.all { it.id.startsWith(owner) })
    }

    @Test fun accountChangeDuringPlaySearchCannotStartTheOldItem() {
        val controls = legacy().transportControls
        api.searchGate = CompletableDeferred()
        main { controls.playFromSearch("podcast", null) }; waitFor { api.searches == 1 }
        val change = CoroutineScope(Dispatchers.Main).launch { library.changeSession("two") }
        waitFor { library.state.value.revision == 2 }
        api.searchGate!!.complete(Unit); runBlocking { change.join() }
        waitFor { PlaybackStatus.state.value.message == null }
        assertFalse(main { observer.isPlaying }); assertNull(main { observer.currentMediaItem })
    }

    @Test fun assistantArticlePreparationUsesOfflineAudioAndLocalTextBookmarks() {
        val store = PreviewStore(app)
        val voice = store.voiceId; store.voiceId = null
        try {
            main { browser.setMediaItem(request(3)); browser.prepare() }
            waitFor(90_000) { observer.currentMediaItem?.mediaId == id(3) && observer.playbackState == Player.STATE_READY || PlaybackStatus.state.value.error != null }
            assertNull(PlaybackStatus.state.value.error); assertFalse(main { observer.isPlaying }); assertEquals(1, api.texts)
            main { browser.play() }; playing(3)
            waitFor { PlaybackStatus.readingPosition.value?.itemId == id(3) }
            main { browser.pause(); browser.seekTo(2_000) }
            waitFor { store.bookmark(id(3)) != null }
        } finally { store.voiceId = voice }
    }

    @Test fun oldBrowseFoldersAreRejectedAfterSwitchingAccounts() {
        val folders = await(main { browser.getChildren(MediaLibraryCatalog.ROOT, 0, 10, null) }).value!!
        assertEquals(0, await(main { browser.subscribe(folders.first().mediaId, null) }).resultCode)
        waitFor { changedFolders[folders.first().mediaId] != null }
        main { changedFolders.clear() }
        runBlocking(Dispatchers.Main) { library.changeSession("two") }
        waitFor { changedFolders[folders.first().mediaId] == 0 }
        assertTrue(await(main { browser.getChildren(folders.first().mediaId, 0, 10, null) }).resultCode < 0)
        assertTrue(await(main { browser.getChildren(MediaLibraryCatalog.ROOT, 0, 10, null) }).value!!.all { it.mediaId.contains(owner) })
    }

    @Test fun legacyBrowsersCanLoadUnpagedFolders() {
        legacy()
        fun children(parent: String): List<PlatformBrowser.MediaItem> {
            val result = CompletableFuture<List<PlatformBrowser.MediaItem>>()
            main { platform!!.subscribe(parent, object : PlatformBrowser.SubscriptionCallback() {
                override fun onChildrenLoaded(parentId: String, children: MutableList<PlatformBrowser.MediaItem>) { result.complete(children) }
                override fun onError(parentId: String) { result.completeExceptionally(IllegalStateException("Folder rejected: $parentId")) }
            }) }
            return result.get(15, TimeUnit.SECONDS)
        }
        val folders = children(MediaLibraryCatalog.ROOT)
        assertEquals(listOf("Latest", "Saved", "Following"), folders.map { it.description.title.toString() })
        assertEquals(listOf(id(1), id(2)), children(folders.first().mediaId!!).map { it.mediaId })
        assertEquals(0, api.texts)
    }

    @Test fun aSeparateAppWithoutMediaAccessCannotBrowseTheLibrary() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val companion = instrumentation.context
        assertNotEquals(app.applicationInfo.uid, companion.applicationInfo.uid)
        val target = Intent().setComponent(ComponentName(companion.packageName, UntrustedMediaBrowserActivity::class.java.name))
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK).putExtra("target_package", app.packageName)
        try {
            main { app.startActivity(target) }
            compose.waitUntil(15_000) {
                instrumentation.uiAutomation.rootInActiveWindow?.findAccessibilityNodeInfosByText("Magpie library access rejected")?.isNotEmpty() == true
            }
            assertFalse(main { observer.isPlaying })
        } finally { main { app.startActivity(Intent(target).putExtra("close", true)) } }
    }

    @Test fun theLibraryServiceWorksWithoutAnOpenAppActivity() {
        scenario!!.close(); scenario = null
        val root = await(main { browser.getLibraryRoot(null) }); assertEquals(0, root.resultCode)
        val controls = legacy().transportControls
        main { controls.playFromMediaId(id(1), null) }; playing(1)
        main { controls.pause() }; waitFor { !observer.isPlaying }
    }
}
