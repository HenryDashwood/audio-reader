package com.henrydashwood.magpie

import android.content.Intent
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.lifecycle.ViewModelProvider
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import com.henrydashwood.magpie.data.*
import com.henrydashwood.magpie.playback.PlaybackService
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Rule
import org.junit.Test

class LiveLibraryTest {
    @get:Rule val compose = createEmptyComposeRule()
    private val app get() = ApplicationProvider.getApplicationContext<MagpieTestApplication>()
    private lateinit var repository: AccountLibrary
    private lateinit var api: Api
    private var scenario: ActivityScenario<MainActivity>? = null
    private class Api : LibraryApi {
        var failing = false
        var requestedFeed: String? = null
        var requestedContent: Int? = null
        var reported = 0
        val article = RemoteEpisode(2, "A saved account article", contentId = 77, wordCount = 4)
        val podcast = RemoteEpisode(1, "Account podcast", source = "Account publication", audioUrl = "asset:///welcome.wav", positionSeconds = 15.0)
        override suspend fun userId(token: String) = "test-account"
        override suspend fun feeds(token: String): List<LibraryFeed> {
            if (failing) throw java.io.IOException()
            return listOf(LibraryFeed("10", "Account publication", 12, false), LibraryFeed("20", "Empty publication", 0, true))
        }
        override suspend fun latest(token: String) = listOf(podcast)
        override suspend fun saved(token: String) = listOf(article)
        override suspend fun episodes(token: String, feedId: String, query: String): List<RemoteEpisode> {
            requestedFeed = feedId
            return if (feedId == "20") emptyList() else listOf(podcast)
        }
        override suspend fun search(token: String, query: String) = listOf(podcast)
        override suspend fun text(token: String, episodeId: Int, contentId: Int?): RemoteText {
            requestedContent = contentId
            return RemoteText(episodeId, 77, "Account article full text.", "<p>Account article full text.</p>", 4)
        }
        override suspend fun save(token: String, episodeId: Int?, url: String?) = article
        override suspend fun remove(token: String, episodeId: Int) {}
        override suspend fun played(token: String, episodeId: Int, played: Boolean) {}
        override suspend fun clearLatest(token: String) {}
        override suspend fun subscribe(token: String, url: String) = LibraryFeed("30", "Added publication", 0, true)
        override suspend fun position(token: String, episodeId: Int, seconds: Double, completed: Boolean) { reported++ }
    }
    @Before fun prepare() {
        app.stopService(Intent(app, PlaybackService::class.java))
        api = Api()
        repository = AccountLibrary(api, "https://test.invalid")
        runBlocking(Dispatchers.Main) { repository.changeSession("test-session") }
        app.libraryOverride = repository
    }
    @After fun finish() {
        scenario?.close()
        app.stopService(Intent(app, PlaybackService::class.java))
        app.libraryOverride = null
    }
    private fun launch() { scenario = ActivityScenario.launch(MainActivity::class.java) }

    @Test fun failedInitialLoadShowsRetryWithoutClaimingTheAccountIsEmpty() {
        api.failing = true
        repository = AccountLibrary(api, "https://test.invalid")
        runBlocking(Dispatchers.Main) { repository.changeSession("test-session") }
        app.libraryOverride = repository
        launch()
        compose.onNodeWithText("Could not connect to Magpie. Check your connection and try again.").assertIsDisplayed()
        compose.onNodeWithText("No sources yet").assertDoesNotExist()
        compose.onNodeWithText("Field notes").assertDoesNotExist()
        api.failing = false
        compose.onNodeWithText("Try again").performClick()
        compose.waitUntil(10_000) { repository.state.value.feeds.isNotEmpty() }
        compose.onNodeWithText("Account publication").assertIsDisplayed()
    }

    @Test fun accountFeedsSavedTextAndLogoutReplaceTheSampleLibrary() {
        launch()
        compose.onNodeWithText("Account publication").assertIsDisplayed()
        compose.onNodeWithText("Empty publication").assertIsDisplayed().performClick()
        compose.waitUntil(10_000) { api.requestedFeed == "20" }
        compose.onNodeWithText("Nothing here yet").assertIsDisplayed()
        compose.onNodeWithContentDescription("Back").performClick()
        compose.onNodeWithText("Saved").performClick()
        compose.onNodeWithText("A saved account article").assertIsDisplayed().performClick()
        compose.waitUntil(10_000) { repository.state.value.items.any { it.episodeId == 2 && it.textLoaded } }
        assertEquals(77, api.requestedContent)
        compose.onNodeWithTag("article-webview").assertExists()
        runBlocking(Dispatchers.Main) { repository.changeSession(null) }
        compose.onNodeWithTag("article-webview").assertDoesNotExist()
        compose.onNodeWithText("Following").performClick()
        compose.onNodeWithText("Field notes").assertIsDisplayed()
        compose.onNodeWithText("Account publication").assertDoesNotExist()
    }
    @Test fun accountPodcastStartsAtItsSavedPositionAndStopsWhenAccountChanges() {
        launch()
        lateinit var model: MagpieModel
        scenario!!.onActivity { model = ViewModelProvider(it)[MagpieModel::class.java] }
        compose.waitUntil(10_000) { model.player.value.connected }
        compose.runOnUiThread { model.play(repository.state.value.items.first { it.episodeId == 1 }) }
        compose.waitUntil(15_000) { model.player.value.playing && model.player.value.positionMs >= 15_000 }
        compose.runOnUiThread { model.pause() }
        compose.waitUntil(10_000) { api.reported > 0 }
        runBlocking(Dispatchers.Main) { repository.changeSession(null) }
        compose.waitUntil(10_000) { model.player.value.item == null && !model.player.value.playing }
    }
    @Test fun wireDecodingHandlesNullsSavedVersionsAndUntrustedAudioUrls() {
        val row = HttpLibraryApi.decodeEpisode(JSONObject("""{"id":9,"title":"Saved","description":null,"feed_title":null,
            "audio_url":null,"duration_seconds":null,"position_seconds":null,"word_count":null,"content_id":88,"has_text":true}"""))
        assertEquals("Saved articles", row.source)
        assertEquals(0.0, row.positionSeconds, 0.0)
        assertEquals(88, row.contentId)
        assertNull(row.wordCount)
        val unsafe = HttpLibraryApi.decodeEpisode(JSONObject("""{"id":9,"title":"Unsafe","audio_url":"file:///private/file"}"""))
        assertNull(unsafe.audioUrl)
        val feed = HttpLibraryApi.decodeFeed(JSONObject("""{"id":20,"title":"Empty","episode_count":0,"sources":[]}"""))
        assertEquals("20", feed.id)
        assertEquals(0, feed.count)
    }
}
