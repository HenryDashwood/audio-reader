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

class ArticleProgressPlaybackTest {
    @get:Rule val compose = createEmptyComposeRule()
    private val app get() = ApplicationProvider.getApplicationContext<MagpieTestApplication>()
    private lateinit var directory: File
    private lateinit var journal: FileArticleProgressStore
    private lateinit var queue: ArticleProgressQueue
    private lateinit var library: AccountLibrary
    private lateinit var api: Api
    private var scenario: ActivityScenario<MainActivity>? = null
    private var controller: MediaController? = null
    private class Api : LibraryApi, ArticleProgressApi {
        var offline = true
        var body = ("A café 🌱 stands beside the river. We stop to read the next passage and watch the birds in the trees. ").repeat(8)
        val hash get() = java.security.MessageDigest.getInstance("SHA-256").digest(body.toByteArray()).joinToString("") { "%02x".format(it) }
        var revision = "a".repeat(64)
        var row = RemoteEpisode(1, "Durable article test", source = "Test publication", contentId = 7)
        val reports = mutableListOf<ArticleProgressReport>()
        override suspend fun articleProgress(token: String, episodeId: Int, report: ArticleProgressReport): ArticleProgressReceipt {
            reports += report
            if (offline) throw IOException("Offline fixture")
            row = row.copy(articleBookmark = RemoteArticleBookmark(report.textVersion, report.offsetUtf16), completed = report.completed)
            revision = "b".repeat(64)
            return ArticleProgressReceipt(row, ArticleProgressState(hash, 7, revision, row.articleBookmark), revision)
        }
        override suspend fun userId(token: String) = "progress-test"
        override suspend fun feeds(token: String) = listOf(LibraryFeed("1", "Test show", 1, false))
        override suspend fun latest(token: String) = listOf(row)
        override suspend fun saved(token: String) = emptyList<RemoteEpisode>()
        override suspend fun episodes(token: String, feedId: String, query: String) = listOf(row)
        override suspend fun search(token: String, query: String) = listOf(row)
        override suspend fun episode(token: String, episodeId: Int) = row
        override suspend fun text(token: String, episodeId: Int, contentId: Int?) = RemoteText(1, 7, body, null, 160,
            ArticleProgressState(hash, 7, revision, row.articleBookmark))
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
        journal = FileArticleProgressStore(directory); queue = ArticleProgressQueue(journal); api = Api()
        library = AccountLibrary(api, "https://progress-test.invalid", articleQueue = queue)
        runBlocking(Dispatchers.Main) { library.changeSession("test-session"); library.content(library.state.value.items.single().id) }
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
        compose.waitUntil(60_000) { compose.runOnUiThread { controller!!.isPlaying && controller!!.duration > 30_000 } }
    }
    private fun entries() = runBlocking { journal.read(library.state.value.owner!!) }
    @Test fun offlinePauseSurvivesFreshJournalAndRetriesOriginalRequestBeforeLatestClock() {
        play()
        compose.runOnUiThread { controller!!.seekTo(15_000); controller!!.pause() }
        compose.waitUntil(10_000) { entries().firstOrNull()?.latest?.offsetUtf16?.let { it > 0 } == true }
        val saved = entries().single(); assertNotNull(saved.pending)
        val reopened = ArticleProgressQueue(FileArticleProgressStore(directory))
        assertEquals(saved, runBlocking { reopened.entries(library.state.value.owner!!).single() })
        api.offline = false
        runBlocking(Dispatchers.Main) { library.flushArticleProgress(); library.flushArticleProgress() }
        assertNull(entries().single().pending)
        assertTrue(api.reports.any { it == saved.pending })
        assertTrue(library.state.value.items.single().articleBookmark!!.offsetUtf16 > 0)
        assertEquals(api.hash, api.reports.last().textVersion); assertEquals(7, api.reports.last().contentId)
    }
    @Test fun explicitPlayUsesNewerServerBookmarkEvenWhenTextWasAlreadyCached() {
        val boundary = api.body.indexOf("A café", 100)
        assertTrue(boundary > 0)
        val offset = boundary + 5
        api.row = api.row.copy(articleBookmark = RemoteArticleBookmark(api.hash, offset))
        api.revision = "c".repeat(64)
        play()
        compose.runOnUiThread { controller!!.pause() }
        compose.waitUntil(10_000) { entries().firstOrNull()?.sampled == true }
        val saved = entries().single()
        // The backend coordinate lies inside a sentence. The local voice starts
        // at its beginning, regardless of how long earlier sentences sounded.
        assertEquals(boundary, saved.latest.offsetUtf16)
        assertEquals(api.hash, saved.latest.textVersion)
        assertEquals("c".repeat(64), saved.baselineRevision)
        assertEquals("c".repeat(64), saved.pending!!.expectedRevision)
        assertTrue(compose.runOnUiThread { controller!!.currentPosition > 1_000 })
    }
    @Test fun longArticleResumesPastTheOldLimitWithTheInstalledOfflineVoiceAndClosesOnAccountChange() {
        api.body = api.body.repeat(60)
        val boundary = api.body.indexOf("A café", 35_000)
        assertTrue(boundary > 30_000)
        api.row = api.row.copy(articleBookmark = RemoteArticleBookmark(api.hash, boundary + 5))
        api.revision = "c".repeat(64)
        play()
        compose.runOnUiThread { controller!!.pause() }
        compose.waitUntil(10_000) { entries().firstOrNull()?.sampled == true }
        assertEquals(boundary, entries().single().latest.offsetUtf16)
        assertEquals(api.hash, entries().single().latest.textVersion)
        assertTrue(File(app.cacheDir, "narration").walkTopDown().filter { it.extension == "wav" }.count() <= 7)
        runBlocking(Dispatchers.Main) { library.changeSession(null) }
        compose.waitUntil(10_000) { compose.runOnUiThread { controller!!.mediaItemCount == 0 && !controller!!.isPlaying } }
        compose.waitUntil(10_000) { File(app.cacheDir, "narration").walkTopDown().none { it.isFile } }
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
        runBlocking(Dispatchers.Main) { library.flushArticleProgress(); library.flushArticleProgress() }
        assertTrue(api.row.completed); assertNull(entries().single().pending)
        assertEquals(api.body.length, api.reports.last().offsetUtf16)
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
        runBlocking(Dispatchers.Main) { library.flushArticleProgress() }
        assertEquals(count, api.reports.size)
        command(PlaybackService.VOICE_CONTROL, "confirm")
        assertTrue(entries().single().guards.isEmpty())
    }
}
