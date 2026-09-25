package com.henrydashwood.magpie

import android.content.Intent
import androidx.activity.compose.setContent
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Density
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createEmptyComposeRule
import androidx.lifecycle.ViewModelProvider
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import androidx.test.platform.app.InstrumentationRegistry
import com.henrydashwood.magpie.data.*
import com.henrydashwood.magpie.playback.ArticleBookmark
import com.henrydashwood.magpie.playback.PlaybackService
import com.henrydashwood.magpie.ui.MagpieApp
import com.henrydashwood.magpie.ui.MagpieTheme
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import org.junit.*
import org.junit.Assert.*
import java.io.File
import java.io.IOException
import java.util.UUID

class SavedPreparationTest {
    @get:Rule val compose = createEmptyComposeRule()
    private val app get() = ApplicationProvider.getApplicationContext<MagpieTestApplication>()
    private lateinit var api: Api
    private lateinit var library: AccountLibrary
    private lateinit var model: MagpieModel
    private var scenario: ActivityScenario<MainActivity>? = null
    private class Api : LibraryApi, SavedArticleApi {
        var offline = false
        var unchanged = false
        var writes = 0
        var row = RemoteEpisode(2, "Saved article", link = "https://example.com/article", contentId = 7, wordCount = 200)
        var rows = listOf(row)
        override suspend fun userId(token: String) = token
        override suspend fun feeds(token: String) = emptyList<LibraryFeed>()
        override suspend fun latest(token: String) = emptyList<RemoteEpisode>()
        override suspend fun saved(token: String) = rows
        override suspend fun episodes(token: String, feedId: String, query: String) = emptyList<RemoteEpisode>()
        override suspend fun search(token: String, query: String) = emptyList<RemoteEpisode>()
        override suspend fun text(token: String, episodeId: Int, contentId: Int?): RemoteText {
            val text = SampleLibrary().items.first { it.id == "walking" }.text
            return RemoteText(episodeId, contentId, text, "<p>$text</p>", 200)
        }
        override suspend fun save(token: String, episodeId: Int?, url: String?) = row
        override suspend fun remove(token: String, episodeId: Int) {}
        override suspend fun played(token: String, episodeId: Int, played: Boolean) {}
        override suspend fun clearLatest(token: String) {}
        override suspend fun subscribe(token: String, url: String) = LibraryFeed("1", "Feed", 0, true)
        override suspend fun position(token: String, episodeId: Int, seconds: Double, completed: Boolean) {}
        override suspend fun capture(token: String, article: PendingArticle): RemoteEpisode {
            writes++; if (offline) throw IOException()
            return row.copy(id = 3, title = "Queued article", link = article.url).also { rows = rows + it }
        }
        override suspend fun retrySaved(token: String, episodeId: Int): RemoteEpisode {
            writes++; if (offline) throw IOException()
            row = row.copy(captureError = null, contentId = 7); rows = listOf(row); return row
        }
        override suspend fun replaceSaved(token: String, episodeId: Int): RemoteEpisode {
            writes++; if (offline) throw IOException()
            if (!unchanged) row = row.copy(contentId = checkNotNull(row.contentId) + 1)
            rows = listOf(row); return row
        }
    }
    @Before fun prepare() {
        app.stopService(Intent(app, PlaybackService::class.java))
        api = Api(); library = AccountLibrary(api, "https://saved-fixture.invalid")
        runBlocking(Dispatchers.Main) {
            library.changeSession("alice")
            val owner = checkNotNull(library.state.value.owner)
            app.articleInbox.pending(owner).forEach { app.articleInbox.remove(owner, it.id) }
        }
        app.libraryOverride = library
        scenario = ActivityScenario.launch(MainActivity::class.java)
        scenario!!.onActivity { model = ViewModelProvider(it)[MagpieModel::class.java] }
        compose.waitUntil(10_000) { model.savedPreparation.state.value.owner != null && !model.savedPreparation.state.value.busy }
        compose.onNodeWithText("Saved").performClick()
        awaitIdle()
    }
    @After fun finish() {
        scenario?.close(); app.stopService(Intent(app, PlaybackService::class.java))
        runBlocking { library.state.value.owner?.let { owner -> app.articleInbox.pending(owner).forEach { app.articleInbox.remove(owner, it.id) } } }
        app.libraryOverride = null
    }
    private fun savedItem() = library.state.value.items.first { it.episodeId == 2 }
    // As on iOS, Replace saved text is in the row's long-press menu, not under every article.
    private fun requestReplace() {
        compose.onNode(hasText("Saved article") and SemanticsMatcher.keyIsDefined(androidx.compose.ui.semantics.SemanticsActions.OnLongClick))
            .performScrollTo().performSemanticsAction(androidx.compose.ui.semantics.SemanticsActions.OnLongClick)
        compose.onNodeWithText("Replace saved text").performClick()
    }
    private fun awaitIdle() { compose.waitUntil(10_000) { !model.savedPreparation.state.value.busy } }
    @Test fun offlineLinkSurvivesRecreationAndSyncsOnlyAfterSuccess() {
        api.offline = true
        compose.onNodeWithContentDescription("Add link").performClick()
        compose.onNode(hasSetTextAction()).performTextInput("https://example.com/queued")
        compose.onNodeWithText("Save", useUnmergedTree = true).performClick()
        compose.waitUntil(10_000) { model.savedPreparation.state.value.pending.size == 1 && !model.savedPreparation.state.value.busy }
        compose.onNodeWithText("Saved on this device · Waiting to sync").assertIsDisplayed()
        scenario!!.recreate()
        compose.onNodeWithText("Saved on this device · Waiting to sync").assertIsDisplayed()
        compose.waitForIdle()
        awaitIdle()
        // Both resuming the activity and opening Saved may retry while offline.
        // What matters is retaining the link until one successful explicit sync.
        val offlineAttempts = api.writes
        assertTrue(offlineAttempts >= 2)
        assertEquals(1, model.savedPreparation.state.value.pending.size)
        assertTrue(api.rows.none { it.id == 3 })
        api.offline = false
        compose.onNodeWithText("Sync saved links").performClick()
        compose.waitUntil(10_000) { model.savedPreparation.state.value.pending.isEmpty() }
        compose.onNodeWithText("Queued article").assertIsDisplayed()
        assertEquals(offlineAttempts + 1, api.writes)
        assertEquals(1, api.rows.count { it.id == 3 })
    }
    @Test fun failedCaptureHasExplicitRetryAndCanBeOpenedAfterPreparation() {
        runBlocking(Dispatchers.Main) {
            api.row = api.row.copy(contentId = null, captureError = "Could not retrieve article."); api.rows = listOf(api.row); library.refresh()
        }
        compose.onNodeWithText("Could not retrieve article.").assertIsDisplayed()
        compose.onNodeWithContentDescription("Retry preparing Saved article").performClick()
        compose.waitUntil(10_000) { savedItem().captureError == null }
        assertEquals(1, api.writes); assertEquals(7, savedItem().contentId)
        compose.onNodeWithText("Saved article").performClick()
        compose.waitUntil(10_000) { savedItem().textLoaded }
    }
    @Test fun deviceLinksRequireConfirmationAndMoveToDurableAccountQueueBeforeRemoval() {
        val url = "https://example.com/device-${UUID.randomUUID()}"
        api.offline = true
        try {
            runBlocking { app.deviceLinkInbox.add(url) }
            runBlocking(Dispatchers.Main) { library.refresh() }
            compose.waitUntil(10_000) { url in model.deviceLinks.value }
            assertEquals(0, api.writes)
            compose.onNodeWithText("Review device links").performClick()
            compose.onNodeWithText(url).assertIsDisplayed()
            compose.onNodeWithText("Cancel").performClick()
            assertTrue(url in app.deviceLinkInbox.links()); assertEquals(0, api.writes)
            compose.onNodeWithText("Review device links").performClick()
            compose.onNodeWithText("Import links").performClick()
            compose.waitUntil(10_000) { !model.importingLinks.value && model.savedPreparation.state.value.pending.any { it.url == url } }
            assertFalse(url in app.deviceLinkInbox.links())
            val persisted = runBlocking { app.articleInbox.pending(checkNotNull(library.state.value.owner)) }
            assertTrue(persisted.any { it.url == url })
        } finally { app.deviceLinkInbox.remove(url) }
    }
    @Test fun confirmationSurvivesRecreationAndCancelOrFailureKeepsTheOldCopy() {
        val loaded = runBlocking(Dispatchers.Main) { library.content(savedItem().id) }
        requestReplace(); scenario!!.recreate()
        compose.onNodeWithText("Replace saved text?").assertIsDisplayed()
        compose.onNodeWithText("Cancel").performClick(); assertEquals(0, api.writes)
        api.offline = true; requestReplace(); compose.onNodeWithText("Replace", useUnmergedTree = true).performClick(); awaitIdle()
        assertEquals(loaded, savedItem())
        api.offline = false; requestReplace(); compose.onNodeWithText("Replace", useUnmergedTree = true).performClick()
        compose.waitUntil(10_000) { savedItem().contentId == 8 }
        assertFalse(savedItem().textLoaded)
    }
    @Test fun changedTextStopsPlaybackAndResetsBookmarkButUnchangedTextKeepsPlaying() {
        val loaded = runBlocking(Dispatchers.Main) { library.content(savedItem().id) }
        compose.waitUntil(10_000) { model.player.value.connected }
        compose.runOnUiThread { model.play(loaded) }
        compose.waitUntil(25_000) { model.player.value.playing }
        api.unchanged = true
        requestReplace(); compose.onNodeWithText("Replace", useUnmergedTree = true).performClick(); awaitIdle()
        assertTrue(model.player.value.playing)
        val store = PreviewStore(app); store.saveBookmark(loaded.id, ArticleBookmark(loaded.contentVersion, 120))
        api.unchanged = false
        requestReplace(); compose.onNodeWithText("Replace", useUnmergedTree = true).performClick()
        compose.waitUntil(10_000) { model.player.value.item == null }
        assertNull(store.bookmark(loaded.id)); assertEquals(8, savedItem().contentId)
    }
    @Test fun accountChangeHidesPendingLinksAndDismissesConfirmation() {
        api.offline = true
        runBlocking(Dispatchers.Main) { model.savedPreparation.add("https://example.com/pending") }; awaitIdle()
        requestReplace()
        runBlocking(Dispatchers.Main) { library.changeSession("bob") }
        compose.waitUntil(10_000) { model.savedPreparation.state.value.revision == library.state.value.revision }
        compose.onNodeWithText("Replace saved text?").assertDoesNotExist()
        assertTrue(model.savedPreparation.state.value.pending.isEmpty())
        runBlocking(Dispatchers.Main) { library.changeSession("alice") }
        compose.waitUntil(10_000) { model.savedPreparation.state.value.pending.size == 1 }
    }
    @Test fun replacementDialogIsUsableAtLargeTextInDarkMode() {
        scenario!!.onActivity { activity -> activity.setContent {
            CompositionLocalProvider(LocalDensity provides Density(LocalDensity.current.density, 2f)) { MagpieTheme(darkTheme = true) { MagpieApp(model) } }
        } }
        compose.onNodeWithText("Saved").performClick(); requestReplace()
        compose.onNodeWithText("Replace", useUnmergedTree = true).assertIsDisplayed()
        compose.onNodeWithText("Cancel").assertIsDisplayed()
        val directory = File(checkNotNull(InstrumentationRegistry.getArguments().getString("additionalTestOutputDir")))
        directory.mkdirs()
        val bitmap = checkNotNull(InstrumentationRegistry.getInstrumentation().uiAutomation.takeScreenshot())
        File(directory, "saved-replacement-large-dark.png").outputStream().use { bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it) }
    }
    @Test fun diskQueuePreservesDateDeduplicatesAndKeepsAccountsSeparate() = runBlocking {
        val name = "saved-storage-test-${UUID.randomUUID()}"
        val first = ArticleInboxStore(app, name)
        val article = PendingArticle(url = "https://example.com/article", savedAt = "2026-09-15T10:00:00Z")
        first.add("alice", article); first.add("alice", article.copy(id = "duplicate"))
        val restored = ArticleInboxStore(app, name)
        assertEquals(listOf(article), restored.pending("alice")); assertTrue(restored.pending("bob").isEmpty())
        restored.remove("alice", article.id); assertTrue(first.pending("alice").isEmpty())
        assertTrue(app.deleteSharedPreferences(name))
    }
}
