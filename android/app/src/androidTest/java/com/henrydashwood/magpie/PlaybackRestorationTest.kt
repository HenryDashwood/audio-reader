package com.henrydashwood.magpie

import android.content.ComponentName
import android.content.Intent
import android.os.Bundle
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.lifecycle.ViewModelProvider
import androidx.media3.common.MediaItem
import androidx.media3.common.Player
import androidx.media3.session.MediaController
import androidx.media3.session.SessionCommand
import androidx.media3.session.SessionToken
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import com.henrydashwood.magpie.data.*
import com.henrydashwood.magpie.playback.*
import kotlinx.coroutines.*
import org.junit.*
import org.junit.Assert.*
import java.util.UUID
import java.util.concurrent.TimeUnit

@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
class PlaybackRestorationTest {
    @get:Rule val compose = createEmptyComposeRule()
    private val app get() = ApplicationProvider.getApplicationContext<MagpieTestApplication>()
    private val store get() = PreviewStore(app)
    private lateinit var api: Api
    private lateinit var library: AccountLibrary
    private var controller: MediaController? = null
    private var scenario: ActivityScenario<MainActivity>? = null
    private var model: MagpieModel? = null
    private var originalLast: String? = null
    private val owner get() = checkNotNull(library.state.value.owner)
    private fun id(number: Int) = "$owner:episode:$number"
    private class Api : LibraryApi {
        val namespace = UUID.randomUUID().toString()
        var first = RemoteEpisode(1, "Restored podcast", source = "Restoration show", audioUrl = "asset:///welcome.wav", positionSeconds = 9.0)
        val second = first.copy(id = 2, title = "New choice", positionSeconds = 2.0)
        val article = RemoteEpisode(3, "Restored reading", source = "Restoration show", contentId = 30)
        var gate: CompletableDeferred<Unit>? = null
        var lookups = 0
        var texts = 0
        override suspend fun userId(token: String) = "$namespace-$token"
        override suspend fun feeds(token: String) = emptyList<LibraryFeed>()
        // The remembered item need not be in Latest or Saved after a restart.
        override suspend fun latest(token: String) = listOf(second, article)
        override suspend fun saved(token: String) = emptyList<RemoteEpisode>()
        override suspend fun episodes(token: String, feedId: String, query: String) = latest(token)
        override suspend fun search(token: String, query: String) = latest(token)
        override suspend fun episode(token: String, episodeId: Int): RemoteEpisode {
            lookups++; if (episodeId == 1) gate?.await()
            return listOf(first, second, article).first { it.id == episodeId }
        }
        override suspend fun text(token: String, episodeId: Int, contentId: Int?): RemoteText {
            texts++
            return RemoteText(episodeId, contentId, "A quiet morning leaves room to listen. The trees are full of birds. We walk beside the garden and enjoy the day.", null, 25)
        }
        override suspend fun save(token: String, episodeId: Int?, url: String?) = first
        override suspend fun remove(token: String, episodeId: Int) {}
        override suspend fun played(token: String, episodeId: Int, played: Boolean) {}
        override suspend fun clearLatest(token: String) {}
        override suspend fun subscribe(token: String, url: String) = error("Not used")
        override suspend fun position(token: String, episodeId: Int, seconds: Double, completed: Boolean) {}
    }
    private fun <T> main(work: () -> T): T = compose.runOnUiThread(work)
    private fun waitFor(condition: () -> Boolean) = compose.waitUntil(15_000) { main(condition) }
    @Suppress("DEPRECATION")
    private fun stop() {
        app.stopService(Intent(app, PlaybackService::class.java))
        compose.waitUntil(15_000) {
            app.getSystemService(android.app.ActivityManager::class.java).getRunningServices(Int.MAX_VALUE)
                .none { it.service.className == PlaybackService::class.java.name }
        }
    }
    private fun connect() {
        controller = main { MediaController.Builder(app, SessionToken(app, ComponentName(app, PlaybackService::class.java))).buildAsync() }.get(15, TimeUnit.SECONDS)
    }
    private fun openApp() {
        scenario = ActivityScenario.launch(MainActivity::class.java)
        scenario!!.onActivity { model = ViewModelProvider(it)[MagpieModel::class.java] }
        if (controller == null) connect()
    }
    private fun closeConnections() {
        if (controller != null) {
            main { controller!!.pause() }
            waitFor { !controller!!.playWhenReady }
        }
        main { controller?.release() }; controller = null
        scenario?.close(); scenario = null; model = null
        stop()
    }
    @Before fun setup() {
        stop(); originalLast = store.lastItem
        api = Api(); library = AccountLibrary(api, "https://restoration.invalid")
        runBlocking(Dispatchers.Main) { library.changeSession("one") }
        app.libraryOverride = library
        store.saveRestoration(owner, null)
    }
    @After fun cleanup() {
        api.gate?.complete(Unit)
        controller?.let { media -> main { media.sendCustomCommand(SessionCommand(PlaybackService.DISMISS_PLAYER, Bundle.EMPTY), Bundle.EMPTY) }.get(10, TimeUnit.SECONDS) }
        closeConnections(); store.saveRestoration(owner, null); store.lastItem = originalLast
        app.libraryOverride = null
    }
    @Test fun appRestoresTheSignedInPodcastPausedWithItsFreshRemotePosition() {
        store.saveRestoration(owner, id(1)); store.savePosition(id(1), 1_000)
        openApp()
        waitFor { controller!!.currentMediaItem?.mediaId == id(1) && controller!!.playbackState == Player.STATE_READY }
        assertFalse(main { controller!!.playWhenReady }); assertEquals(9_000L, main { controller!!.currentPosition })
        assertEquals(id(1), model!!.player.value.item?.id)
        // A second service lifetime reads the updated remote clock, not the old local player.
        closeConnections(); api.first = api.first.copy(positionSeconds = 15.0)
        openApp()
        waitFor { controller!!.currentMediaItem?.mediaId == id(1) && controller!!.playbackState == Player.STATE_READY }
        assertEquals(15_000L, main { controller!!.currentPosition }); assertFalse(main { controller!!.isPlaying })
    }
    @Test fun articleRestorationIsSilentAndLoadsTextOnlyWhenSystemPlayIsRequested() {
        store.saveRestoration(owner, id(3)); openApp()
        waitFor { model!!.player.value.item?.id == id(3) }
        assertEquals(0, api.texts); assertNull(main { controller!!.currentMediaItem })
        assertNull(PlaybackStatus.state.value.message); assertFalse(main { controller!!.isPlaying })
        main { controller!!.play() }
        waitFor { controller!!.currentMediaItem?.mediaId == id(3) && controller!!.isPlaying }
        assertTrue(api.texts > 0); assertNull(PlaybackStatus.state.value.error)
    }
    @Test fun systemPlayResumesAfterServiceRecreationWithoutOpeningTheActivity() {
        store.saveRestoration(owner, id(1)); connect()
        assertNull(main { controller!!.currentMediaItem })
        main { controller!!.play() }
        waitFor { controller!!.currentMediaItem?.mediaId == id(1) && controller!!.isPlaying }
        main { controller!!.pause() }; closeConnections()
        connect(); assertNull(main { controller!!.currentMediaItem })
        main { controller!!.play() }
        waitFor { controller!!.currentMediaItem?.mediaId == id(1) && controller!!.isPlaying }
    }
    @Test fun pauseCancelsDelayedSystemResumption() {
        api.gate = CompletableDeferred(); store.saveRestoration(owner, id(1)); connect()
        main { controller!!.play() }
        waitFor { api.lookups > 0 }
        main { controller!!.pause() }
        waitFor { !controller!!.playWhenReady }
        api.gate!!.complete(Unit)
        // Allow the cancelled resolver and queued Media3 commands to finish.
        runBlocking { delay(500) }
        assertNull(main { controller!!.currentMediaItem }); assertFalse(main { controller!!.isPlaying })
    }
    @Test fun dismissingThePlayerPreventsRestorationButKeepsExplicitContinue() {
        store.saveRestoration(owner, id(1)); openApp()
        waitFor { controller!!.currentMediaItem?.mediaId == id(1) }
        main { controller!!.sendCustomCommand(SessionCommand(PlaybackService.DISMISS_PLAYER, Bundle.EMPTY), Bundle.EMPTY) }.get(10, TimeUnit.SECONDS)
        assertNull(store.restoration(owner)); assertEquals(id(1), store.continuation(owner))
        closeConnections(); openApp()
        waitFor { model!!.player.value.connected }
        assertNull(model!!.player.value.item); assertNull(main { controller!!.currentMediaItem })
    }
    @Test fun aNewPlaybackChoiceWinsOverALatePassiveRestore() {
        api.gate = CompletableDeferred(); store.saveRestoration(owner, id(1)); openApp()
        waitFor { api.lookups > 0 }
        main { controller!!.setMediaItem(MediaItem.Builder().setMediaId(id(2)).build()); controller!!.prepare(); controller!!.play() }
        waitFor { controller!!.currentMediaItem?.mediaId == id(2) && controller!!.isPlaying }
        api.gate!!.complete(Unit)
        assertEquals(id(2), store.restoration(owner))
    }
    @Test fun accountChangesDiscardThePendingRestoreAndItsStoredChoice() {
        val previousOwner = owner
        api.gate = CompletableDeferred(); store.saveRestoration(owner, id(1)); openApp()
        waitFor { api.lookups > 0 }
        runBlocking(Dispatchers.Main) { library.changeSession("two") }
        api.gate!!.complete(Unit)
        waitFor { model!!.libraryState.value.owner != previousOwner }
        assertNull(store.restoration(previousOwner)); assertNull(main { controller!!.currentMediaItem })
        assertNull(model!!.player.value.item)
    }
    @Test fun startingVoiceCancelsPendingPassiveRestoration() {
        api.gate = CompletableDeferred(); store.saveRestoration(owner, id(1)); openApp()
        waitFor { api.lookups > 0 }
        val args = Bundle().apply { putString("token", UUID.randomUUID().toString()); putInt("revision", library.state.value.revision) }
        val result = main { controller!!.sendCustomCommand(SessionCommand(PlaybackService.BEGIN_VOICE, Bundle.EMPTY), args) }.get(10, TimeUnit.SECONDS)
        assertEquals(androidx.media3.session.SessionResult.RESULT_SUCCESS, result.resultCode)
        api.gate!!.complete(Unit)
        runBlocking { delay(500) }
        assertNull(main { controller!!.currentMediaItem }); assertFalse(main { controller!!.isPlaying })
    }
    @Test fun completedItemsAreNotResurrectedIntoThePlayer() {
        api.first = api.first.copy(completed = true)
        store.lastItem = id(1)
        store.saveRestoration(owner, id(1)); openApp()
        waitFor { store.restoration(owner) == null && model!!.player.value.item == null }
        assertNull(main { controller!!.currentMediaItem }); assertFalse(main { controller!!.playWhenReady })
    }
}
