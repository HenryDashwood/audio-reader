package com.henrydashwood.magpie

import android.content.ComponentName
import android.content.Intent
import android.os.Bundle
import androidx.compose.ui.test.junit4.v2.createEmptyComposeRule
import androidx.media3.session.MediaController
import androidx.media3.session.SessionCommand
import androidx.media3.session.SessionToken
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import com.henrydashwood.magpie.data.*
import com.henrydashwood.magpie.playback.PlaybackService
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import java.io.File
import java.io.IOException
import java.util.UUID
import java.util.concurrent.TimeUnit

class PodcastProgressPlaybackTest {
    @get:Rule val compose = createEmptyComposeRule()
    private val app get() = ApplicationProvider.getApplicationContext<MagpieTestApplication>()
    private lateinit var directory: File
    private lateinit var journal: FilePodcastProgressStore
    private lateinit var queue: PodcastProgressQueue
    private lateinit var library: AccountLibrary
    private lateinit var api: Api
    private var scenario: ActivityScenario<MainActivity>? = null
    private var controller: MediaController? = null
    private class Api : LibraryApi, PodcastProgressApi {
        var offline = true
        var row = RemoteEpisode(1, "Durable progress test", source = "Test show", audioUrl = "asset:///welcome.wav", progressRevision = "a".repeat(64))
        val reports = mutableListOf<PodcastProgressReport>()
        override suspend fun podcastProgress(token: String, episodeId: Int, report: PodcastProgressReport): PodcastProgressReceipt {
            reports += report
            if (offline) throw IOException("Offline fixture")
            row = row.copy(positionSeconds = report.seconds, completed = report.completed, progressRevision = "b".repeat(64))
            return PodcastProgressReceipt(row, row.progressRevision!!)
        }
        override suspend fun userId(token: String) = "progress-test"
        override suspend fun feeds(token: String) = listOf(LibraryFeed("1", "Test show", 1, false))
        override suspend fun latest(token: String) = listOf(row)
        override suspend fun saved(token: String) = emptyList<RemoteEpisode>()
        override suspend fun episodes(token: String, feedId: String, query: String) = listOf(row)
        override suspend fun search(token: String, query: String) = listOf(row)
        override suspend fun episode(token: String, episodeId: Int) = row
        override suspend fun text(token: String, episodeId: Int, contentId: Int?): RemoteText = error("Podcast has no article text")
        override suspend fun save(token: String, episodeId: Int?, url: String?) = row
        override suspend fun remove(token: String, episodeId: Int) {}
        override suspend fun played(token: String, episodeId: Int, played: Boolean) { error("Guarded completion must not use legacy filing") }
        override suspend fun clearLatest(token: String) {}
        override suspend fun subscribe(token: String, url: String) = LibraryFeed("1", "Test show", 1, false)
        override suspend fun position(token: String, episodeId: Int, seconds: Double, completed: Boolean) { error("Guarded playback must not use legacy position") }
    }
    @Before fun setup() {
        app.stopService(Intent(app, PlaybackService::class.java))
        directory = File(app.noBackupFilesDir, "playback-progress-test-${UUID.randomUUID()}")
        journal = FilePodcastProgressStore(directory); queue = PodcastProgressQueue(journal); api = Api()
        library = AccountLibrary(api, "https://progress-test.invalid", progressQueue = queue)
        runBlocking(Dispatchers.Main) { library.changeSession("test-session") }
        app.libraryOverride = library
        scenario = ActivityScenario.launch(MainActivity::class.java)
        controller = compose.runOnUiThread { MediaController.Builder(app,
            SessionToken(app, ComponentName(app, PlaybackService::class.java))).buildAsync() }.get(10, TimeUnit.SECONDS)
    }
    @After fun cleanup() {
        controller?.let { compose.runOnUiThread { it.pause(); it.release() } }
        scenario?.close(); app.stopService(Intent(app, PlaybackService::class.java))
        runBlocking(Dispatchers.Main) { library.changeSession(null) }
        app.libraryOverride = null; directory.deleteRecursively()
    }
    private fun play() {
        val id = library.state.value.items.single().id
        assertEquals(0, compose.runOnUiThread { controller!!.sendCustomCommand(SessionCommand(PlaybackService.PLAY_ITEM, Bundle.EMPTY),
            Bundle().apply { putString("id", id) }) }.get(10, TimeUnit.SECONDS).resultCode)
        compose.waitUntil(15_000) { compose.runOnUiThread { controller!!.isPlaying && controller!!.duration > 30_000 } }
    }
    private fun entries() = runBlocking { journal.read(library.state.value.owner!!) }
    @Test fun offlinePauseSurvivesFreshJournalAndRetriesOriginalRequestBeforeLatestClock() {
        play()
        compose.runOnUiThread { controller!!.seekTo(15_000); controller!!.pause() }
        compose.waitUntil(10_000) { entries().firstOrNull()?.latest?.seconds?.let { it >= 15 } == true }
        val saved = entries().single(); assertNotNull(saved.pending)
        val reopened = PodcastProgressQueue(FilePodcastProgressStore(directory))
        assertEquals(saved, runBlocking { reopened.entries(library.state.value.owner!!).single() })
        api.offline = false
        runBlocking(Dispatchers.Main) { library.flushPodcastProgress(); library.flushPodcastProgress() }
        assertNull(entries().single().pending)
        assertTrue(api.reports.any { it == saved.pending })
        assertTrue(library.state.value.items.single().remotePositionMs >= 15_000)
    }
    @Test fun naturalCompletionQueuesFinishedAndClearsPlayerWithoutSeparateLegacyWrite() {
        play()
        compose.runOnUiThread { controller!!.seekTo(controller!!.duration - 200) }
        compose.waitUntil(10_000) { entries().firstOrNull()?.latest?.completed == true }
        // Disk commit precedes the main-thread library overlay. Wait for both
        // observable completion effects, rather than racing the IO continuation.
        compose.waitUntil(5_000) { compose.runOnUiThread {
            controller!!.mediaItemCount == 0 && library.state.value.items.single().completed
        } }
        api.offline = false
        runBlocking(Dispatchers.Main) { library.flushPodcastProgress(); library.flushPodcastProgress() }
        assertTrue(api.row.completed); assertNull(entries().single().pending)
    }
    @Test fun voiceDrainPersistsGuardAndConfirmationReleasesOnlyThatRequest() {
        play()
        fun command(action: String, value: String? = null) {
            val result = compose.runOnUiThread { controller!!.sendCustomCommand(SessionCommand(action, Bundle.EMPTY), Bundle().apply {
                putString("token", "voice-test"); putInt("revision", library.state.value.revision)
                if (value != null) { putString("action", value); putString("request_id", "filing-request") }
            }) }.get(10, TimeUnit.SECONDS)
            assertEquals(0, result.resultCode)
        }
        command(PlaybackService.BEGIN_VOICE)
        command(PlaybackService.VOICE_CONTROL, "drain")
        assertEquals(setOf("filing-request"), entries().single().guards)
        val count = api.reports.size; api.offline = false
        runBlocking(Dispatchers.Main) { library.flushPodcastProgress() }
        assertEquals(count, api.reports.size)
        command(PlaybackService.VOICE_CONTROL, "confirm")
        assertTrue(entries().single().guards.isEmpty())
    }
}
