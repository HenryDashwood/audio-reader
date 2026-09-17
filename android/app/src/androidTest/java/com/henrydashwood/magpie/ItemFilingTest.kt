package com.henrydashwood.magpie

import android.content.Intent
import androidx.activity.compose.setContent
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.unit.Density
import androidx.lifecycle.ViewModelProvider
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import androidx.test.platform.app.InstrumentationRegistry
import com.henrydashwood.magpie.data.*
import com.henrydashwood.magpie.playback.PlaybackService
import com.henrydashwood.magpie.ui.MagpieApp
import com.henrydashwood.magpie.ui.MagpieTheme
import com.henrydashwood.magpie.voice.*
import kotlinx.coroutines.*
import org.junit.*
import org.junit.Assert.*
import java.io.File
import java.io.IOException
import java.util.UUID

class ItemFilingTest {
    @get:Rule val compose = createEmptyComposeRule()
    private val app get() = ApplicationProvider.getApplicationContext<MagpieTestApplication>()
    private lateinit var api: Api
    private lateinit var library: AccountLibrary
    private lateinit var model: MagpieModel
    private lateinit var directory: File
    private var scenario: ActivityScenario<MainActivity>? = null
    private class Api : LibraryApi, LibraryActionApi {
        var rows = listOf(
            RemoteEpisode(1, "A garden podcast", source = "Garden notes", audioUrl = "asset:///welcome.wav", positionSeconds = 2.0),
            RemoteEpisode(2, "A garden article", source = "Garden notes", contentId = 7),
        )
        val calls = mutableListOf<Triple<String, Int?, String>>()
        val receipts = mutableMapOf<String, VoiceResponse>()
        var loseReply = false
        var gate: CompletableDeferred<Unit>? = null
        var writes = 0
        var writesAfterFiling = 0
        override suspend fun userId(token: String) = token
        override suspend fun feeds(token: String) = listOf(LibraryFeed("10", "Garden notes", 2, false))
        override suspend fun latest(token: String) = rows.filter { !it.completed && !it.dismissed }
        override suspend fun saved(token: String) = rows.filter { it.id == 2 }
        override suspend fun episodes(token: String, feedId: String, query: String) = rows
        override suspend fun search(token: String, query: String) = rows
        override suspend fun episode(token: String, episodeId: Int) = rows.first { it.id == episodeId }
        override suspend fun text(token: String, episodeId: Int, contentId: Int?) = RemoteText(episodeId, 7, "Birds sing in the garden.\n\nThere is time to listen.", null, 11)
        override suspend fun save(token: String, episodeId: Int?, url: String?) = rows.last()
        override suspend fun remove(token: String, episodeId: Int) {}
        override suspend fun played(token: String, episodeId: Int, played: Boolean) = error("Use the recoverable typed route")
        override suspend fun clearLatest(token: String) {}
        override suspend fun subscribe(token: String, url: String) = feeds(token).first()
        override suspend fun position(token: String, episodeId: Int, seconds: Double, completed: Boolean) {
            if (rows.first { it.id == episodeId }.completed && !completed) writesAfterFiling++
        }
        override suspend fun libraryAction(token: String, action: String, episodeId: Int?, requestId: String): VoiceResponse {
            calls += Triple(action, episodeId, requestId)
            gate?.await()
            val receipt = receipts.getOrPut(requestId) {
                writes++
                val row = rows.first { it.id == episodeId }.let {
                    when (action) {
                        "mark_played" -> it.copy(completed = true)
                        "dismiss" -> it.copy(dismissed = true)
                        "restore" -> it.copy(completed = false, dismissed = false, positionSeconds = 0.0)
                        else -> error("Unexpected action")
                    }
                }
                rows = rows.map { if (it.id == row.id) row else it }
                VoiceResponse(VoiceAction.decode(action), "Library updated", row)
            }
            if (loseReply) throw IOException("Reply lost")
            return receipt
        }
        override suspend fun cancelLibraryAction(token: String, requestId: String) {}
    }
    @Before fun prepare() {
        app.stopService(Intent(app, PlaybackService::class.java))
        directory = File(app.cacheDir, "filing-test-${UUID.randomUUID()}")
        api = Api()
        library = repository()
        app.libraryOverride = library
        app.voiceOutputOverride = VoiceOutput { }
        launch()
    }
    private fun repository() = AccountLibrary(api, "https://filing.invalid",
        conversationStore = FileConversationStore(directory)).also { runBlocking(Dispatchers.Main) { it.changeSession("fixture") } }
    private fun launch() {
        scenario = ActivityScenario.launch(MainActivity::class.java)
        scenario!!.onActivity { model = ViewModelProvider(it)[MagpieModel::class.java] }
        compose.waitUntil(10_000) { model.player.value.connected }
    }
    @After fun finish() {
        scenario?.close(); app.stopService(Intent(app, PlaybackService::class.java))
        app.libraryOverride = null; app.voiceOutputOverride = null
        directory.deleteRecursively()
    }
    private fun rowNode(title: String) = compose.onNode(hasText(title) and
        SemanticsMatcher.keyIsDefined(androidx.compose.ui.semantics.SemanticsActions.OnLongClick))
    private fun actions(title: String) {
        val toolbar = compose.onAllNodesWithContentDescription("Actions for $title").fetchSemanticsNodes()
        if (toolbar.isNotEmpty()) compose.onNodeWithContentDescription("Actions for $title").performClick()
        else rowNode(title).performSemanticsAction(androidx.compose.ui.semantics.SemanticsActions.OnLongClick)
    }
    private fun settled() { compose.waitUntil(15_000) { !model.itemFiling.state.value.busy }; assertNull(model.itemFiling.state.value.error) }
    private fun row(id: Int) = library.state.value.items.first { it.episodeId == id }
    @Test fun latestDismissAndFeedRestorationUseVisibleMenus() {
        compose.onNodeWithText("Latest").performClick()
        actions("A garden article"); compose.onNodeWithText("Dismiss from Latest").performClick(); settled()
        assertFalse(row(2).completed); assertTrue(row(2).dismissed)
        compose.onNodeWithText("A garden article").assertDoesNotExist()
        compose.onNodeWithText("Following").performClick(); compose.onNodeWithText("Garden notes").performClick()
        // Wait for the publication fetch before opening its transient menu.
        compose.waitUntil(10_000) { !model.libraryState.value.searching && model.libraryState.value.feedResults.isNotEmpty() }
        actions("A garden article"); compose.onNodeWithText("Restore to Latest").performClick(); settled()
        assertFalse(row(2).dismissed)
        compose.onNodeWithContentDescription("Back").performClick(); compose.onNodeWithText("Latest").performClick()
        compose.onNodeWithText("A garden article").assertIsDisplayed()
        assertEquals(listOf("dismiss", "restore"), api.calls.map { it.first })
    }
    @Test fun rowSwipesMatchIOSAndTalkBackCanFileWithoutGestures() {
        compose.onNodeWithText("Latest").performClick()
        for (title in listOf("A garden podcast", "A garden article")) {
            compose.onNodeWithContentDescription("Actions for $title").assertDoesNotExist()
            rowNode(title).performTouchInput { swipeRight() }; settled()
            compose.onNodeWithText(title).assertDoesNotExist()
        }
        assertTrue(api.rows.all { it.dismissed && !it.completed })
        compose.onNodeWithText("Following").performClick(); compose.onNodeWithText("Garden notes").performClick()
        compose.waitUntil(10_000) { !model.libraryState.value.searching && model.libraryState.value.feedResults.size == 2 }
        rowNode("A garden podcast").performTouchInput { swipeLeft() }; settled()
        assertFalse(row(1).dismissed); assertFalse(row(1).completed)
        // Publication rows have no leading dismissal swipe, as on iOS.
        rowNode("A garden podcast").performTouchInput { swipeRight() }
        assertEquals(listOf("dismiss", "dismiss", "restore"), api.calls.map { it.first })
        val actions = rowNode("A garden podcast").fetchSemanticsNode()
            .config[androidx.compose.ui.semantics.SemanticsActions.CustomActions]
        compose.runOnUiThread { assertTrue(actions.first { it.label == "Mark as played" }.action()) }
        settled(); assertTrue(row(1).completed)
    }
    @Test fun podcastFinishClearsActivePlaybackAndUnplayedRestoresItWithoutAnOldClock() {
        compose.runOnUiThread { model.play(row(1)) }
        compose.waitUntil(15_000) { model.player.value.playing }
        compose.onNodeWithText("Latest").performClick()
        actions("A garden podcast"); compose.onNodeWithText("Mark as played").performClick(); settled()
        compose.waitUntil(10_000) { model.player.value.item == null }
        assertTrue(row(1).completed); assertEquals(0, api.writesAfterFiling)
        compose.onNodeWithText("Following").performClick(); compose.onNodeWithText("Garden notes").performClick()
        actions("A garden podcast"); compose.onNodeWithText("Mark as unplayed").performClick(); settled()
        assertFalse(row(1).completed); assertEquals(0L, row(1).remotePositionMs)
        assertFalse(model.player.value.playing)
    }
    @Test fun articleReadAndUnreadAreAvailableFromReaderAndSaved() {
        compose.onNodeWithText("Latest").performClick(); compose.onNodeWithText("A garden article").performClick()
        compose.waitUntil(10_000) { row(2).textLoaded }
        val store = PreviewStore(app)
        store.saveBookmark(row(2).id, com.henrydashwood.magpie.playback.ArticleBookmark(row(2).contentVersion, 5))
        actions("A garden article"); compose.onNodeWithText("Mark as read").performClick(); settled()
        assertTrue(row(2).completed)
        compose.onNodeWithContentDescription("Back").performClick(); compose.onNodeWithText("Saved").performClick()
        compose.onNodeWithText("Finished").performClick()
        actions("A garden article"); compose.onNodeWithText("Mark as unread").performClick(); settled()
        compose.onNodeWithText("To read").performClick(); compose.onNodeWithText("A garden article").assertIsDisplayed()
        assertFalse(row(2).completed)
        // Unread resets the bookmark; it must not reuse the service's Undo copy.
        assertNull(store.bookmark(row(2).id))
    }
    @Test fun lostReplyAndFreshRepositoryReuseTheOriginalRequest() {
        api.loseReply = true
        compose.onNodeWithText("Latest").performClick()
        actions("A garden podcast"); compose.onNodeWithText("Mark as played").performClick()
        compose.waitUntil(10_000) { model.itemFiling.state.value.error != null }
        assertFalse(row(1).completed); assertEquals(1, api.writes)
        val requestId = api.calls.single().third
        scenario!!.close(); app.stopService(Intent(app, PlaybackService::class.java))
        library = repository(); app.libraryOverride = library; api.loseReply = false
        launch()
        // The fresh snapshot knows it was filed. The old request remains in
        // Ask Magpie, so check it instead of creating a second filing action.
        compose.runOnUiThread { model.ask() }
        compose.waitUntil(10_000) { model.voice.state.value.recoveryRequests.isNotEmpty() }
        val pending = model.voice.state.value.recoveryRequests.single()
        assertEquals(requestId, pending.requestId)
        compose.runOnUiThread { model.voice.retryRequest(pending.requestId) }
        compose.waitUntil(15_000) { model.voice.state.value.recoveryRequests.isEmpty() }
        assertEquals(1, api.writes)
        assertTrue(row(1).completed)
        assertTrue(api.calls.all { it.third == requestId })
    }
    @Test fun doubleTapAndAccountChangeCannotApplyAnOldReceipt() {
        api.gate = CompletableDeferred()
        compose.runOnUiThread {
            model.fileItem(row(1), ItemFilingAction.Finish)
            model.fileItem(row(1), ItemFilingAction.Finish)
        }
        compose.waitUntil(10_000) { api.calls.size == 1 }
        runBlocking(Dispatchers.Main) { library.changeSession(null); api.gate!!.complete(Unit) }
        compose.waitUntil(10_000) { !model.itemFiling.state.value.busy }
        assertFalse(library.state.value.live); assertNull(model.itemFiling.state.value.error)
        assertTrue(library.state.value.items.none { it.episodeId == 1 })
        assertEquals(1, api.calls.size)
    }
    @Test fun retryButtonChecksTheSameRequestWithoutRepeatingTheWrite() {
        api.loseReply = true
        compose.onNodeWithText("Latest").performClick()
        actions("A garden article"); compose.onNodeWithText("Mark as read").performClick()
        compose.waitUntil(10_000) { model.itemFiling.state.value.error != null }
        val request = api.calls.single()
        api.loseReply = false
        compose.onNodeWithText("Retry change").performClick(); settled()
        assertEquals(1, api.writes)
        assertEquals(listOf(request, request), api.calls)
        assertTrue(row(2).completed)
    }
    @Test fun anotherLibraryRequestKeepsItsLeaseAndPlaybackWhenARowActionIsRequested() {
        compose.runOnUiThread { model.play(row(1)) }
        compose.waitUntil(15_000) { model.player.value.playing }
        compose.runOnUiThread {
            assertTrue(library.voiceConversation.acquire("other-request"))
            model.fileItem(row(2), ItemFilingAction.Finish)
        }
        compose.waitUntil(10_000) { model.itemFiling.state.value.error != null }
        assertTrue(api.calls.isEmpty())
        assertTrue(model.player.value.playing)
        compose.runOnUiThread { library.voiceConversation.release("other-request") }
    }
    @Test fun largeTextDarkModeMenusAndSearchResultsRemainReachable() {
        scenario!!.onActivity { activity -> activity.setContent {
            CompositionLocalProvider(LocalDensity provides Density(activity.resources.displayMetrics.density, 2f)) {
                MagpieTheme(darkTheme = true) { MagpieApp(model) }
            }
        } }
        compose.onNodeWithContentDescription("Search").performClick()
        compose.onNodeWithText("Search your library").performTextInput("garden")
        compose.waitUntil(10_000) { library.state.value.searchResults.size == 2 }
        compose.onNodeWithTag("following-list").performScrollToNode(hasText("A garden podcast"))
        actions("A garden podcast")
        compose.onNodeWithText("Mark as played").assertIsDisplayed()
        compose.onNodeWithText("Dismiss from Latest").assertIsDisplayed()
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val bitmap = checkNotNull(instrumentation.uiAutomation.takeScreenshot())
        val output = InstrumentationRegistry.getArguments().getString("additionalTestOutputDir")?.let(::File) ?: File(app.filesDir, "screenshots")
        output.mkdirs(); File(output, "item-filing-large-dark.png").outputStream().use { bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it) }
        compose.onNodeWithText("Mark as played").performClick(); settled()
        assertTrue(row(1).completed)
    }
}
