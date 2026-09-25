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

class SourceManagementTest {
    @get:Rule val compose = createEmptyComposeRule()
    private val app get() = ApplicationProvider.getApplicationContext<MagpieTestApplication>()
    private lateinit var api: Api
    private lateinit var library: AccountLibrary
    private var scenario: ActivityScenario<MainActivity>? = null
    private class Api : LibraryApi, SourceManagementApi {
        var grouped = false
        var unsubscribed = false
        var fail = false
        var writes = 0
        val primary = FeedSource("1", "Main publication", "https://public.example/feed?access_token=private-secret", "rss", primary = true)
        val child = FeedSource("2", "Other publication", "email://private-address", "email", failing = true)
        val root get() = LibraryFeed("1", "Main publication", if (grouped) 2 else 1, false, "https://public.example/feed", sourceDetails = if (grouped) listOf(primary, child) else listOf(primary), forwarded = true)
        val other get() = LibraryFeed("2", "Other publication", 1, true, sourceDetails = listOf(child.copy(primary = true)))
        override suspend fun userId(token: String) = "fixture"
        override suspend fun feeds(token: String) = if (unsubscribed) emptyList() else if (grouped) listOf(root) else listOf(root, other)
        val podcast = RemoteEpisode(10, "Listening episode", source = "Main publication", audioUrl = "asset:///welcome.wav", positionSeconds = 2.0)
        override suspend fun latest(token: String) = if (unsubscribed) emptyList() else listOf(podcast)
        override suspend fun saved(token: String) = listOf(RemoteEpisode(20, "Saved stays here", contentId = 7))
        override suspend fun episodes(token: String, feedId: String, query: String) = if (grouped) listOf(podcast, RemoteEpisode(11, "Combined article")) else listOf(podcast)
        override suspend fun search(token: String, query: String) = emptyList<RemoteEpisode>()
        override suspend fun text(token: String, episodeId: Int, contentId: Int?) = RemoteText(episodeId, contentId, "Saved text.", null, 2)
        override suspend fun save(token: String, episodeId: Int?, url: String?) = saved(token).single()
        override suspend fun remove(token: String, episodeId: Int) {}
        override suspend fun played(token: String, episodeId: Int, played: Boolean) {}
        override suspend fun clearLatest(token: String) {}
        override suspend fun subscribe(token: String, url: String) = root
        override suspend fun position(token: String, episodeId: Int, seconds: Double, completed: Boolean) {}
        override suspend fun feedSources(token: String, feedId: String) = if (grouped) listOf(child, primary) else listOf(primary)
        override suspend fun changeSources(token: String, feedId: String, sourceId: String?, change: SourceChange) {
            if (fail) throw java.io.IOException()
            writes++
            when (change) {
                SourceChange.Combine -> { assertEquals("2", sourceId); grouped = true }
                SourceChange.Separate -> { assertEquals("2", sourceId); grouped = false }
                SourceChange.Unsubscribe -> unsubscribed = true
            }
        }
    }
    @Before fun prepare() {
        app.stopService(Intent(app, PlaybackService::class.java))
        api = Api(); library = AccountLibrary(api, "https://fixture.invalid")
        runBlocking(Dispatchers.Main) { library.changeSession("fixture-token") }
        app.libraryOverride = library; scenario = ActivityScenario.launch(MainActivity::class.java)
    }
    @After fun finish() { scenario?.close(); app.stopService(Intent(app, PlaybackService::class.java)); app.libraryOverride = null }
    private fun openMenu() {
        compose.onNodeWithText("Main publication").performClick()
        compose.onNodeWithContentDescription("Manage Main publication").performClick()
    }
    private fun manage() { openMenu(); compose.onNodeWithText("Manage sources").performClick() }
    @Test fun combineAndSeparateRefreshTheFeedAndPreserveSaved() {
        manage()
        compose.onNodeWithText("public.example").assertIsDisplayed()
        compose.onNodeWithText("private-secret", substring = true).assertDoesNotExist()
        compose.onNodeWithContentDescription("Combine Other publication with Main publication").performScrollTo().performClick()
        compose.onNodeWithText("Sources combined").performScrollTo().assertIsDisplayed()
        compose.onNodeWithContentDescription("Separate Other publication, Email newsletter").performScrollTo().assertIsDisplayed()
        compose.onNodeWithText("This source is not updating").assertIsDisplayed()
        scenario!!.recreate()
        compose.onNodeWithContentDescription("Separate Other publication, Email newsletter").performScrollTo().performClick()
        compose.onNodeWithContentDescription("Combine Other publication with Main publication").performScrollTo().assertIsDisplayed()
        assertEquals(2, api.writes)
        compose.onNodeWithText("Done").performClick()
        compose.onNodeWithText("Saved").performClick()
        compose.onNodeWithText("Saved stays here").assertIsDisplayed()
    }
    @Test fun failedCombineKeepsSubscriptionsAndCanBeRetried() {
        manage(); api.fail = true
        compose.onNodeWithContentDescription("Combine Other publication with Main publication").performScrollTo().performClick()
        compose.onNodeWithText("Could not connect to Magpie. Check your connection and try again.").performScrollTo().assertIsDisplayed()
        assertEquals(2, library.state.value.feeds.size); assertEquals(0, api.writes)
        api.fail = false
        compose.onNodeWithContentDescription("Combine Other publication with Main publication").performScrollTo().performClick()
        assertEquals(1, library.state.value.feeds.size)
    }
    @Test fun unsubscribeReturnsToFollowingWhilePlaybackAndSavedRemain() {
        lateinit var model: MagpieModel
        scenario!!.onActivity { model = ViewModelProvider(it)[MagpieModel::class.java] }
        compose.waitUntil(10_000) { model.player.value.connected }
        compose.runOnUiThread { model.play(library.state.value.items.first { it.episodeId == 10 }) }
        compose.waitUntil(15_000) { model.player.value.playing }
        openMenu(); compose.onNodeWithText("Unsubscribe").performClick()
        compose.waitUntil(10_000) { library.state.value.feeds.isEmpty() }
        compose.onNodeWithText("Nothing followed yet").assertIsDisplayed()
        assertTrue(model.player.value.playing); assertEquals(10, model.player.value.item?.episodeId)
        compose.onNodeWithText("Saved").performClick(); compose.onNodeWithText("Saved stays here").assertIsDisplayed()
    }
    @Test fun largeTextManagementIsScrollableAndSessionChangesDismissIt() {
        scenario!!.onActivity { activity ->
            val model = ViewModelProvider(activity)[MagpieModel::class.java]
            activity.setContent { CompositionLocalProvider(LocalDensity provides Density(LocalDensity.current.density, 2f)) { MagpieTheme(darkTheme = true) { MagpieApp(model) } } }
        }
        manage()
        compose.onNodeWithContentDescription("Combine Other publication with Main publication").performScrollTo().assertIsDisplayed()
        val supplied = InstrumentationRegistry.getArguments().getString("additionalTestOutputDir")
        val directory = supplied?.let(::File) ?: File(app.filesDir, "screenshots")
        directory.mkdirs()
        val bitmap = checkNotNull(InstrumentationRegistry.getInstrumentation().uiAutomation.takeScreenshot())
        File(directory, "source-management-large-dark.png").outputStream().use { bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it) }
        // As on iOS, unsubscribing lives in the show's menu, not in Manage sources.
        compose.onNodeWithContentDescription("Unsubscribe from Main publication").assertDoesNotExist()
        runBlocking(Dispatchers.Main) { library.changeSession(null) }
        compose.onNodeWithText("Sources in Main publication").assertDoesNotExist()
        compose.onNodeWithText("Field notes").assertIsDisplayed()
    }
    @Test fun wireMetadataIncludesSourceIdentityPrimaryStatusAndForwarding() {
        val feed = HttpLibraryApi.decodeFeed(JSONObject("""{"id":1,"title":"Publication","forwarded":true,"sources":[{"id":2,"title":"Publication","url":"https://example.com/private?token=secret","source":"rss","is_primary":true,"is_failing":true}]}"""))
        assertTrue(feed.forwarded)
        val source = feed.sourceDetails.single()
        assertEquals("2", source.id); assertTrue(source.primary); assertTrue(source.failing); assertEquals("example.com", source.location)
    }
}
