package com.henrydashwood.magpie

import android.content.Intent
import androidx.activity.compose.setContent
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Density
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.lifecycle.ViewModelProvider
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import androidx.test.platform.app.InstrumentationRegistry
import com.henrydashwood.magpie.data.*
import com.henrydashwood.magpie.auth.AccountFailure
import com.henrydashwood.magpie.playback.PlaybackService
import com.henrydashwood.magpie.ui.MagpieApp
import com.henrydashwood.magpie.ui.MagpieTheme
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import org.junit.*
import org.junit.Assert.*
import java.io.File

class SubscriptionImportUiTest {
    @get:Rule val compose = createEmptyComposeRule()
    private val app get() = ApplicationProvider.getApplicationContext<MagpieTestApplication>()
    private lateinit var api: Api
    private lateinit var library: AccountLibrary
    private var scenario: ActivityScenario<MainActivity>? = null
    private class Api : LibraryApi, SubscriptionImportApi, SubscriptionExportApi {
        var exportXML: String? = null
        override suspend fun exportSubscriptions(token: String): String = exportXML ?: throw AccountFailure(409, "There are no podcast or RSS subscriptions to export yet.")
        var mutations = 0
        var job: ImportJob? = null
        val review = ImportJob("review", "draft", 1, true, 0, 0, 0, 0, 0, 0,
            listOf(ImportItem(7, "Fixture podcast", "example.org", "ready", null, false, false),
                ImportItem(8, "Already here", "example.org", "already_following", null, false, false)))
        override suspend fun currentImport(token: String) = job
        override suspend fun previewImport(token: String, bytes: ByteArray): ImportJob { job = review; return review }
        override suspend fun mutateImport(token: String, id: String, action: String, requestId: String?, entries: Set<Int>?): ImportJob {
            mutations++
            job = review.copy(status = if (action == "stop") "stopped" else "running", total = 1,
                items = review.items.map { it.copy(status = if (action == "stop") "stopped" else "processing", selected = true) })
            return job!!
        }
        override suspend fun userId(token: String) = "fixture-user"
        override suspend fun feeds(token: String) = emptyList<LibraryFeed>()
        override suspend fun latest(token: String) = emptyList<RemoteEpisode>()
        override suspend fun saved(token: String) = emptyList<RemoteEpisode>()
        override suspend fun episodes(token: String, feedId: String, query: String) = emptyList<RemoteEpisode>()
        override suspend fun search(token: String, query: String) = emptyList<RemoteEpisode>()
        override suspend fun text(token: String, episodeId: Int, contentId: Int?) = error("Unused")
        override suspend fun save(token: String, episodeId: Int?, url: String?) = error("Unused")
        override suspend fun remove(token: String, episodeId: Int) {}
        override suspend fun played(token: String, episodeId: Int, played: Boolean) {}
        override suspend fun clearLatest(token: String) {}
        override suspend fun subscribe(token: String, url: String): LibraryFeed = error("Unused")
        override suspend fun position(token: String, episodeId: Int, seconds: Double, completed: Boolean) {}
    }
    @Before fun prepare() {
        app.stopService(Intent(app, PlaybackService::class.java))
        api = Api(); library = AccountLibrary(api, "https://fixture.invalid")
        runBlocking(Dispatchers.Main) { library.changeSession("fixture-token") }
        app.libraryOverride = library
        scenario = ActivityScenario.launch(MainActivity::class.java)
    }
    @After fun finish() { scenario?.close(); app.stopService(Intent(app, PlaybackService::class.java)); app.libraryOverride = null }
    private fun open() {
        compose.onNodeWithContentDescription("Add sources").performClick()
        compose.onNodeWithText("Import subscriptions").performClick()
    }
    private fun capture(name: String) {
        val automation = InstrumentationRegistry.getInstrumentation().uiAutomation
        automation.waitForIdle(500, 5_000)
        val bitmap = checkNotNull(automation.takeScreenshot())
        val supplied = InstrumentationRegistry.getArguments().getString("additionalTestOutputDir")
        val directory = (supplied?.let(::File) ?: File(app.filesDir, "screenshots")).apply { mkdirs() }
        File(directory, name).outputStream().use { bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it) }
        bitmap.recycle()
    }
    @Test fun entryPointExplainsFileImportWithoutSubscribing() {
        open()
        compose.onNodeWithTag("choose-opml").assertIsDisplayed()
        compose.onNodeWithText("How to export from your app").performClick()
        compose.onNodeWithText("This imports subscriptions. Reading and listening history aren’t included.").assertIsDisplayed()
        assertEquals(0, api.mutations)
    }
    @Test fun pendingExportSurvivesRecreationButNotAnAccountChange() {
        api.exportXML = "<opml><body>private</body></opml>"
        compose.onNodeWithText("Settings").performClick()
        compose.onNodeWithTag("settings-list").performScrollToNode(hasText("Export subscriptions"))
        compose.onNodeWithText("Export subscriptions").performClick()
        lateinit var model: MagpieModel
        scenario!!.onActivity { model = ViewModelProvider(it)[MagpieModel::class.java] }
        runBlocking(Dispatchers.Main) { model.exportSubscriptions() }
        scenario!!.recreate()
        scenario!!.onActivity { model = ViewModelProvider(it)[MagpieModel::class.java] }
        assertEquals(api.exportXML, model.pendingSubscriptionExport.value?.xml)
        runBlocking(Dispatchers.Main) { library.changeSession("other-token") }
        compose.waitUntil(10_000) { model.pendingSubscriptionExport.value == null }
    }
    @Test fun settingsOffersExportAndShowsAnEmptyLibraryError() {
        compose.onNodeWithText("Settings").performClick()
        compose.onNodeWithTag("settings-list").performScrollToNode(hasText("Export subscriptions"))
        compose.onNodeWithText("Export subscriptions").assertIsDisplayed()
        capture("subscription-export-settings.png")
        compose.onNodeWithText("Export subscriptions").performClick()
        compose.onNodeWithText("Export OPML file").assertIsEnabled().performClick()
        compose.onNodeWithText("There are no podcast or RSS subscriptions to export yet.").assertIsDisplayed()
        assertEquals(0, api.mutations)
        capture("subscription-export-empty.png")
    }
    @Test fun reviewStartsWithoutConfirmationAndCanStopAfterReopening() {
        api.job = api.review
        open()
        compose.onNodeWithText("Import 1 subscription").performScrollTo().assertIsEnabled()
        compose.onNodeWithText("Import 1 subscription").performScrollTo().performClick()
        compose.onNodeWithText("You can leave this screen. Magpie will keep importing.").assertIsDisplayed()
        compose.onNodeWithText("Done").performClick()
        open()
        compose.onNodeWithText("Stop import").performClick()
        compose.waitUntil(10_000) { compose.onAllNodesWithText("Import stopped").fetchSemanticsNodes().isNotEmpty() }
        assertEquals(2, api.mutations)
    }
    @Test fun reviewRemainsUsableAtLargeTextInDarkMode() {
        api.job = api.review
        scenario!!.onActivity { activity ->
            val model = ViewModelProvider(activity)[MagpieModel::class.java]
            activity.setContent {
                MagpieTheme(darkTheme = true) {
                    val density = LocalDensity.current
                    CompositionLocalProvider(LocalDensity provides Density(density.density, 2f)) { MagpieApp(model) }
                }
            }
        }
        open()
        compose.onNodeWithText("Import 1 subscription").performScrollTo().assertIsEnabled()
        // Compose idleness does not include the platform dialog fade.
        InstrumentationRegistry.getInstrumentation().uiAutomation.waitForIdle(500, 5_000)
        val bitmap = checkNotNull(InstrumentationRegistry.getInstrumentation().uiAutomation.takeScreenshot())
        val supplied = InstrumentationRegistry.getArguments().getString("additionalTestOutputDir")
        val directory = (supplied?.let(::File) ?: File(app.filesDir, "screenshots")).apply { mkdirs() }
        File(directory, "import-review-large-dark.png").outputStream().use { bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it) }
        bitmap.recycle()
    }
}
