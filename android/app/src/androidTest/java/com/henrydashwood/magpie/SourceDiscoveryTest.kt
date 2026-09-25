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
import com.henrydashwood.magpie.playback.PlaybackService
import com.henrydashwood.magpie.ui.MagpieApp
import com.henrydashwood.magpie.ui.MagpieTheme
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import org.junit.*
import org.junit.Assert.*
import java.io.File

class SourceDiscoveryTest {
    @get:Rule val compose = createEmptyComposeRule()
    private val app get() = ApplicationProvider.getApplicationContext<MagpieTestApplication>()
    private lateinit var api: Api
    private lateinit var library: AccountLibrary
    private var scenario: ActivityScenario<MainActivity>? = null
    private class Api : LibraryApi, DiscoveryApi, SourceManagementApi {
        var followed = 0
        var webCalls = 0
        var grants = 0
        var consent = false
        var failure = false
        var previewed: String? = null
        val feed = LibraryFeed("9", "Fixture publication", 1, true, "https://fixture.example/feed", description = "A publication to preview.")
        override suspend fun userId(token: String) = "fixture-user"
        override suspend fun feeds(token: String) = if (followed > 0) listOf(feed) else emptyList()
        override suspend fun latest(token: String) = emptyList<RemoteEpisode>()
        override suspend fun saved(token: String) = emptyList<RemoteEpisode>()
        override suspend fun episodes(token: String, feedId: String, query: String) = emptyList<RemoteEpisode>()
        override suspend fun search(token: String, query: String) = emptyList<RemoteEpisode>()
        override suspend fun text(token: String, episodeId: Int, contentId: Int?) = RemoteText(episodeId, 6, "Read this before subscribing.", "<p>Read this before subscribing.</p>", 5)
        override suspend fun save(token: String, episodeId: Int?, url: String?) = RemoteEpisode(90, "Preview article")
        override suspend fun remove(token: String, episodeId: Int) {}
        override suspend fun played(token: String, episodeId: Int, played: Boolean) {}
        override suspend fun clearLatest(token: String) {}
        override suspend fun subscribe(token: String, url: String): LibraryFeed { if (failure) throw java.io.IOException(); followed++; return feed }
        override suspend fun position(token: String, episodeId: Int, seconds: Double, completed: Boolean) {}
        override suspend fun feedSources(token: String, feedId: String) = emptyList<FeedSource>()
        override suspend fun changeSources(token: String, feedId: String, sourceId: String?, change: SourceChange) {
            assertEquals(SourceChange.Unsubscribe, change); followed = 0
        }
        override suspend fun directory(token: String, query: String) = if (query == "unlisted") emptyList() else listOf(SourceResult("Fixture podcast", feed.url!!, "Fixture publisher", 1))
        override suspend fun discover(token: String, url: String) = listOf(SourceResult("Main feed", feed.url!!, primary = true), SourceResult("Comments feed", "https://fixture.example/comments"))
        override suspend fun preview(token: String, url: String): RemotePreview {
            previewed = url
            return RemotePreview(feed.copy(url = url), listOf(RemoteEpisode(90, "Preview article", contentId = 6)), followed > 0)
        }
        override suspend fun webSearch(token: String, query: String): SourceResult? { webCalls++; return SourceResult("Web publication", feed.url!!) }
        override suspend fun aiConsent(token: String) = consent
        override suspend fun setAIConsent(token: String, granted: Boolean): Boolean { grants++; consent = granted; return consent }
    }
    @Before fun prepare() {
        app.stopService(Intent(app, PlaybackService::class.java))
        api = Api(); library = AccountLibrary(api, "https://fixture.invalid")
        runBlocking(Dispatchers.Main) { library.changeSession("fixture-token") }
        app.libraryOverride = library
        scenario = ActivityScenario.launch(MainActivity::class.java)
    }
    @After fun finish() { scenario?.close(); app.stopService(Intent(app, PlaybackService::class.java)); app.libraryOverride = null }
    private fun search(query: String) {
        compose.onNodeWithContentDescription("Add sources").performClick()
        compose.onNodeWithTag("source-query").performTextInput(query)
    }
    private fun capture(name: String) {
        compose.waitForIdle()
        val bitmap = checkNotNull(InstrumentationRegistry.getInstrumentation().uiAutomation.takeScreenshot())
        val directory = File(app.filesDir, "screenshots").apply { mkdirs() }
        File(directory, "$name.png").outputStream().use { bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it) }
    }
    @Test fun directoryPreviewRequiresExplicitSubscribeAndRecoversFromFailure() {
        search("fixture")
        compose.waitUntil(10_000) { compose.onAllNodesWithText("Fixture podcast").fetchSemanticsNodes().isNotEmpty() }
        compose.onNodeWithText("Fixture podcast").performClick()
        compose.onNodeWithText("Preview article").assertIsDisplayed()
        assertEquals(0, api.followed)
        scenario!!.recreate()
        compose.onNodeWithText("Preview article").assertIsDisplayed()
        api.failure = true
        compose.onNodeWithContentDescription("Subscribe to Fixture publication").performClick()
        compose.onNodeWithText("Could not connect to Magpie. Check your connection and try again.").assertIsDisplayed()
        assertEquals(0, api.followed)
        api.failure = false
        compose.onNodeWithContentDescription("Subscribe to Fixture publication").performClick()
        compose.onNodeWithText("Subscribed").assertIsDisplayed()
        capture("discovery-subscribed")
        compose.onNodeWithContentDescription("Unsubscribe from Fixture publication").performClick()
        compose.onNodeWithText("Subscribed").assertDoesNotExist()
        assertTrue(library.state.value.feeds.isEmpty())
        compose.onNodeWithContentDescription("Subscribe to Fixture publication").performClick()
        compose.onNodeWithText("Subscribed").assertIsDisplayed()
        compose.onNodeWithText("Done").performClick()
        compose.onNodeWithText("Fixture publication").assertIsDisplayed()
        assertEquals(1, api.followed)
    }
    @Test fun websiteOffersFeedChoiceAndArticlesOpenWithoutSubscribingAtLargeText() {
        scenario!!.onActivity { activity ->
            val model = ViewModelProvider(activity)[MagpieModel::class.java]
            activity.setContent {
                CompositionLocalProvider(LocalDensity provides Density(LocalDensity.current.density, 2f)) {
                    MagpieTheme(darkTheme = true) { MagpieApp(model) }
                }
            }
        }
        search("https://fixture.example")
        compose.onNodeWithText("Open podcast or feed").performClick()
        compose.onNodeWithText("Choose a feed").assertIsDisplayed()
        assertNull(api.previewed)
        compose.onNodeWithContentDescription("Recommended").assertIsDisplayed()
        capture("discovery-candidates-large-dark")
        compose.onNodeWithText("Comments feed").performClick()
        assertEquals("https://fixture.example/comments", api.previewed)
        compose.onNodeWithTag("source-discovery-list").performScrollToNode(hasText("Preview article"))
        compose.onNodeWithText("Preview article").performClick()
        compose.waitUntil(10_000) { library.state.value.items.any { it.episodeId == 90 && it.textLoaded } }
        compose.onNodeWithTag("article-webview").assertExists()
        assertEquals(0, api.followed)
    }
    @Test fun webSearchConsentCanBeDeclinedGrantedAndWithdrawnInSettings() {
        // Web search is offered only when nothing matched, as on iOS.
        search("unlisted")
        compose.waitUntil(10_000) { compose.onAllNodesWithText("Search the web for a publication").fetchSemanticsNodes().isNotEmpty() }
        assertEquals(0, api.webCalls)
        compose.onNodeWithText("Search the web for a publication").performScrollTo().performClick()
        compose.onNodeWithText("Use AI for voice and web search?").assertIsDisplayed()
        compose.onNodeWithText("Not Now").performClick()
        assertEquals(0, api.grants); assertEquals(0, api.webCalls)
        compose.onNodeWithText("Search the web for a publication").performScrollTo().performClick()
        compose.onNodeWithContentDescription("Allow AI data sharing").performClick()
        compose.onNodeWithText("Web publication").performScrollTo().assertIsDisplayed()
        assertTrue(api.consent); assertEquals(1, api.webCalls)
        compose.onNodeWithText("Done").performClick()
        compose.onNodeWithText("Settings").performClick()
        compose.onNodeWithTag("settings-list").performScrollToNode(hasText("Turn Off AI Data Sharing"))
        compose.onNodeWithText("Turn Off AI Data Sharing").performClick()
        compose.onNodeWithText("Turn off AI data sharing?").assertIsDisplayed() // asks first, as on iOS
        compose.onNodeWithText("Turn Off").performClick()
        compose.onNodeWithTag("settings-list").performScrollToNode(hasText("Review AI Data Sharing"))
        compose.onNodeWithText("Review AI Data Sharing").assertIsDisplayed()
        assertFalse(api.consent)
    }
    @Test fun accountChangeClosesDiscoveryAndDiscardsItsPreview() {
        search("fixture")
        compose.waitUntil(10_000) { compose.onAllNodesWithText("Fixture podcast").fetchSemanticsNodes().isNotEmpty() }
        compose.onNodeWithText("Fixture podcast").performClick()
        runBlocking(Dispatchers.Main) { library.changeSession(null) }
        compose.onNodeWithText("Preview article").assertDoesNotExist()
        compose.onNodeWithText("Field notes").assertIsDisplayed()
    }
    @Test fun wireDecodersPreserveCandidateMetadataAndSubscribedState() {
        val candidate = HttpLibraryApi.decodeCandidate(JSONObject("""{"title":"Main","feed_url":"https://example.com/rss","format":"rss","item_count":10,"audio_item_count":0,"is_primary":true,"recent_item_titles":["Latest"],"description":null}"""))
        assertTrue(candidate.primary); assertEquals("Latest", candidate.recentTitle); assertEquals(10, candidate.count)
        val preview = HttpLibraryApi.decodePreview(JSONObject("""{"feed":{"id":9,"title":"Feed","url":"https://example.com/rss","episode_count":0,"description":null},"episodes":[],"subscribed":true}"""))
        assertTrue(preview.subscribed); assertTrue(preview.episodes.isEmpty())
        assertTrue(runCatching { HttpLibraryApi.decodeSource(JSONObject("""{"title":"Unsafe","feed_url":"file:///private/file"}""")) }.isFailure)
    }
}
