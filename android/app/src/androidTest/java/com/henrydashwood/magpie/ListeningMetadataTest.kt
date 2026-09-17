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
import coil3.ColorImage
import coil3.ImageLoader
import coil3.SingletonImageLoader
import coil3.test.FakeImageLoaderEngine
import com.henrydashwood.magpie.data.*
import com.henrydashwood.magpie.playback.MediaLibraryCatalog
import com.henrydashwood.magpie.playback.PlaybackService
import com.henrydashwood.magpie.ui.MagpieApp
import com.henrydashwood.magpie.ui.MagpieTheme
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import org.junit.*
import org.junit.Assert.*
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.UUID
import java.util.concurrent.CopyOnWriteArrayList

@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
@OptIn(coil3.annotation.DelicateCoilApi::class)
class ListeningMetadataTest {
    @get:Rule val compose = createEmptyComposeRule()
    private val app get() = ApplicationProvider.getApplicationContext<MagpieTestApplication>()
    private lateinit var api: Api
    private lateinit var library: AccountLibrary
    private lateinit var model: MagpieModel
    private lateinit var directory: File
    private lateinit var originalImages: ImageLoader
    private lateinit var images: ImageLoader
    private val imageRequests = CopyOnWriteArrayList<String>()
    private var scenario: ActivityScenario<MainActivity>? = null
    private class Api(audio: String) : LibraryApi {
        val cover = "https://publisher.example/cover.png"
        var rows = listOf(
            RemoteEpisode(1, "Continue podcast", source = "Garden notes", audioUrl = audio, durationSeconds = 600,
                positionSeconds = 120.0, publishedAt = "2026-09-16T12:00:00Z", imageUrl = cover),
            RemoteEpisode(2, "New article", source = "Garden notes", contentId = 7, wordCount = 100,
                publishedAt = "2026-09-17T12:00:00Z", imageUrl = cover),
            RemoteEpisode(3, "Finished article", source = "Garden notes", contentId = 8, completed = true),
            RemoteEpisode(4, "Dismissed podcast", source = "Garden notes", audioUrl = audio, durationSeconds = 600,
                positionSeconds = 120.0, dismissed = true),
        )
        override suspend fun userId(token: String) = token
        override suspend fun feeds(token: String) = listOf(LibraryFeed("10", "Garden notes", 4, false, imageUrl = cover))
        override suspend fun latest(token: String) = rows.filter { !it.completed && !it.dismissed }
        override suspend fun saved(token: String) = rows.filter { it.id == 3 }
        override suspend fun episodes(token: String, feedId: String, query: String) = rows
        override suspend fun search(token: String, query: String) = rows
        override suspend fun episode(token: String, episodeId: Int) = rows.first { it.id == episodeId }
        override suspend fun text(token: String, episodeId: Int, contentId: Int?) = RemoteText(episodeId, contentId, "A quiet garden.", null, 3)
        override suspend fun save(token: String, episodeId: Int?, url: String?) = rows[1]
        override suspend fun remove(token: String, episodeId: Int) {}
        override suspend fun played(token: String, episodeId: Int, played: Boolean) {}
        override suspend fun clearLatest(token: String) {}
        override suspend fun subscribe(token: String, url: String) = feeds(token).first()
        override suspend fun position(token: String, episodeId: Int, seconds: Double, completed: Boolean) {
            rows = rows.map { if (it.id == episodeId) it.copy(positionSeconds = seconds, completed = completed) else it }
        }
    }
    @Before fun setup() {
        app.stopService(Intent(app, PlaybackService::class.java))
        directory = File(app.cacheDir, "metadata-${UUID.randomUUID()}").apply { mkdirs() }
        // Five minutes of local silent PCM: real Media3 duration differs from the feed's ten-minute claim.
        val bytes = 300 * 16_000
        val buffer = ByteBuffer.allocate(44 + bytes).order(ByteOrder.LITTLE_ENDIAN)
        buffer.put("RIFF".toByteArray()).putInt(36 + bytes).put("WAVEfmt ".toByteArray()).putInt(16)
            .putShort(1).putShort(1).putInt(8_000).putInt(16_000).putShort(2).putShort(16)
            .put("data".toByteArray()).putInt(bytes)
        val audio = File(directory, "podcast.wav").apply { writeBytes(buffer.array()) }
        api = Api(audio.toURI().toString())
        library = AccountLibrary(api, "https://metadata.invalid", cache = FileLibraryCache(File(directory, "cache")))
        runBlocking(Dispatchers.Main) { library.changeSession("fixture") }
        app.libraryOverride = library
        originalImages = SingletonImageLoader.get(app)
        val engine = FakeImageLoaderEngine.Builder().intercept({ value ->
            (value.toString() == api.cover).also { if (it) imageRequests += value.toString() }
        }, ColorImage(0xff3c896d.toInt())).build()
        images = ImageLoader.Builder(app).components { add(engine) }.build()
        SingletonImageLoader.setUnsafe(images)
        scenario = ActivityScenario.launch(MainActivity::class.java)
        scenario!!.onActivity { model = ViewModelProvider(it)[MagpieModel::class.java] }
        compose.waitUntil(10_000) { model.player.value.connected }
    }
    @After fun finish() {
        scenario?.close(); app.stopService(Intent(app, PlaybackService::class.java)); app.libraryOverride = null
        SingletonImageLoader.setUnsafe(originalImages); images.shutdown(); directory.deleteRecursively()
    }
    @Test fun continueSectionMovesEachUnfinishedItemOnceAndPreservesDatesArtworkAndCache() {
        compose.waitUntil(10_000) { imageRequests.isNotEmpty() }
        compose.onNodeWithText("Latest").performClick()
        compose.onNodeWithText("Continue listening").assertIsDisplayed()
        compose.onNodeWithText("8 min left").assertIsDisplayed()
        compose.onAllNodesWithText("Continue podcast").assertCountEquals(1)
        compose.onNodeWithText(publicationDate("2026-09-16T12:00:00Z")!!).assertIsDisplayed()
        compose.onNodeWithText("Dismissed podcast").assertDoesNotExist()
        compose.onNodeWithText("Finished article").assertDoesNotExist()
        scenario!!.recreate()
        compose.onNodeWithText("Continue listening").assertIsDisplayed()
        compose.onAllNodesWithText("Continue podcast").assertCountEquals(1)
        val snapshot = runBlocking { FileLibraryCache(File(directory, "cache")).load(library.state.value.owner!!)!! }
        assertEquals(api.cover, snapshot.items.first { it.episodeId == 1 }.imageUrl)
        assertEquals("2026-09-16T12:00:00Z", snapshot.items.first { it.episodeId == 1 }.publishedAt)
        assertEquals(api.cover, snapshot.feeds.single().imageUrl)
        assertTrue(imageRequests.all { it == api.cover })
    }
    @Test fun rowFollowsTheLiveMeasuredClockAndPauseWithoutDuplicatingTheCurrentItem() {
        compose.onNodeWithText("Latest").performClick()
        compose.onNodeWithContentDescription("Play Continue podcast").performClick()
        compose.waitUntil(15_000) { model.player.value.playing && model.player.value.durationMs == 300_000L }
        compose.onNodeWithText("Playing · 3 min left").assertIsDisplayed()
        compose.runOnUiThread { model.seek(195_000); model.pause() }
        compose.waitUntil(10_000) { !model.player.value.playing && model.player.value.positionMs >= 195_000 }
        compose.onNodeWithText("Paused · 2 min left").assertIsDisplayed()
        compose.onAllNodes(hasText("Continue podcast") and hasAnyAncestor(hasTestTag("story-list"))).assertCountEquals(1)
        val item = library.state.value.items.first { it.episodeId == 1 }
        assertEquals(api.cover, MediaLibraryCatalog.media(item).mediaMetadata.artworkUri.toString())
    }
    @Test fun feedShowsReadAndDismissedLabelsAndAccountChangeRemovesMetadata() {
        compose.onNodeWithText("Garden notes").performClick()
        compose.onNodeWithTag("story-list").performScrollToNode(hasText("Read"))
        compose.onNodeWithText("Read").assertIsDisplayed()
        compose.onNodeWithTag("story-list").performScrollToNode(hasText("8 min left · Dismissed"))
        compose.onNodeWithText("8 min left · Dismissed").assertIsDisplayed()
        runBlocking(Dispatchers.Main) { library.changeSession(null) }
        compose.onNodeWithText("Garden notes").assertDoesNotExist()
        compose.onNodeWithText("Continue podcast").assertDoesNotExist()
    }
    @Test fun largeTextDarkMetadataAndArtworkRemainReadable() {
        scenario!!.onActivity { activity -> activity.setContent {
            CompositionLocalProvider(LocalDensity provides Density(activity.resources.displayMetrics.density, 2f)) {
                MagpieTheme(darkTheme = true) { MagpieApp(model) }
            }
        } }
        compose.onNodeWithText("Latest").performClick()
        compose.onNodeWithTag("story-list").performScrollToNode(hasText("8 min left"))
        compose.onNodeWithText("8 min left").assertIsDisplayed()
        compose.onNodeWithContentDescription("Actions for Continue podcast").assertDoesNotExist()
        compose.onNodeWithText("Continue podcast").assertHasClickAction()
        compose.waitUntil(10_000) { imageRequests.size >= 2 }
        val bitmap = checkNotNull(InstrumentationRegistry.getInstrumentation().uiAutomation.takeScreenshot())
        val output = InstrumentationRegistry.getArguments().getString("additionalTestOutputDir")?.let(::File) ?: File(app.filesDir, "screenshots")
        output.mkdirs(); File(output, "listening-metadata-large-dark.png").outputStream().use { bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it) }
    }
    @Test fun metadataWireIsAdditiveAndRejectsUnsafeArtwork() {
        val old = JSONObject("""{"id":1,"title":"Episode"}""")
        assertNull(HttpLibraryApi.decodeEpisode(old).imageUrl); assertNull(HttpLibraryApi.decodeEpisode(old).publishedAt)
        val row = HttpLibraryApi.decodeEpisode(old.put("image_url", api.cover).put("published_at", "2026-09-17T12:00:00Z"))
        assertEquals(api.cover, row.imageUrl); assertEquals("2026-09-17T12:00:00Z", row.publishedAt)
        assertNull(HttpLibraryApi.decodeEpisode(old.put("image_url", "file:///private/artwork")).imageUrl)
        assertNull(HttpLibraryApi.decodeEpisode(old.put("image_url", "https://user:password@publisher.example/image")).imageUrl)
    }
}
