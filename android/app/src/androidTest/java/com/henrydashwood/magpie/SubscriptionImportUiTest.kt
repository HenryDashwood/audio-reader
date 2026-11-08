package com.henrydashwood.magpie

import android.app.Activity
import android.net.Uri
import android.content.Intent
import androidx.activity.compose.LocalActivityResultRegistryOwner
import androidx.activity.result.ActivityResultRegistry
import androidx.activity.result.ActivityResultRegistryOwner
import androidx.activity.result.contract.ActivityResultContract
import androidx.core.app.ActivityOptionsCompat
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
import com.henrydashwood.magpie.auth.AccountFailure
import com.henrydashwood.magpie.playback.PlaybackService
import com.henrydashwood.magpie.ui.MagpieApp
import com.henrydashwood.magpie.ui.MagpieTheme
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.withContext
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
        data class Retry(val jobId: String, val requestId: String)
        val retries = mutableListOf<Retry>()
        var mutations = 0
        val previews = mutableListOf<Pair<String, String>>()
        var job: ImportJob? = null
        val review = ImportJob("review", "draft", 1, true, 0, 0, 0, 0, 0, 0,
            listOf(ImportItem(7, "Fixture podcast", "example.org", "ready", null, false, false),
                ImportItem(8, "Already here", "example.org", "already_following", null, false, false)))
        var statusGate: CompletableDeferred<Unit>? = null
        override suspend fun currentImport(token: String): ImportJob? {
            val snapshot = job
            val gate = statusGate
            if (gate != null) {
                statusGate = null
                withContext(NonCancellable) { gate.await() }
            }
            return snapshot
        }
        override suspend fun previewImport(token: String, bytes: ByteArray): ImportJob {
            previews += token to bytes.decodeToString()
            job = review
            return review
        }
        override suspend fun mutateImport(token: String, id: String, action: String, requestId: String?, entries: Set<Int>?): ImportJob {
            mutations++
            if (action == "retry") {
                retries += Retry(id, requireNotNull(requestId))
                if (retries.size == 1) throw java.io.IOException("Retry response lost")
                val source = checkNotNull(job)
                check(source.id == id)
                val pending = source.items.filter { it.retryable && it.status == "failed" }
                    .map { it.copy(status = "pending", retryable = false) }
                return source.copy(id = "next", status = "queued", total = pending.size, finished = 0,
                    added = 0, failed = 0, items = pending).also { job = it }
            }
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
    @Test fun previousAccountsPickerCannotImportItsFileForTheNextAccount() = checkLatePicker(true)
    @Test fun dismissedPickerCannotImportItsFileIntoAReopenedDialog() = checkLatePicker(false)

    private fun checkLatePicker(switchAccount: Boolean) {
        val requests = mutableListOf<Int>()
        val registry = object : ActivityResultRegistry() {
            override fun <I, O> onLaunch(requestCode: Int, contract: ActivityResultContract<I, O>, input: I, options: ActivityOptionsCompat?) {
                assertEquals(Intent.ACTION_OPEN_DOCUMENT, contract.createIntent(app, input).action)
                requests += requestCode
            }
        }
        val registryOwner = object : ActivityResultRegistryOwner { override val activityResultRegistry = registry }
        lateinit var model: MagpieModel
        scenario!!.onActivity { activity ->
            model = ViewModelProvider(activity)[MagpieModel::class.java]
            activity.setContent { CompositionLocalProvider(LocalActivityResultRegistryOwner provides registryOwner) {
                MagpieTheme { MagpieApp(model) }
            } }
        }
        val first = File.createTempFile("first", ".opml", app.cacheDir)
        val second = File.createTempFile("second", ".opml", app.cacheDir)
        try {
            first.writeText("<opml><body>Private first feed</body></opml>")
            second.writeText("<opml><body>Second feed</body></opml>")
            open()
            compose.onNodeWithTag("choose-opml").performClick()
            if (switchAccount) runBlocking(Dispatchers.Main) { library.changeSession("second-token") }
            else compose.onNodeWithText("Done").performClick()
            compose.onNodeWithTag("choose-opml").assertDoesNotExist()
            compose.runOnUiThread { model.subscriptionImport.open() }
            compose.onNodeWithTag("choose-opml").performClick()
            fun deliver(index: Int, file: File) = compose.runOnUiThread {
                registry.dispatchResult(requests[index], Activity.RESULT_OK, Intent().setData(Uri.fromFile(file)))
            }
            compose.runOnIdle { assertEquals(2, requests.size) }
            deliver(0, first)
            compose.waitForIdle()
            compose.waitUntil(10_000) {
                compose.onAllNodesWithContentDescription("Updating import").fetchSemanticsNodes().isEmpty()
            }
            compose.runOnIdle { assertEquals(emptyList<Pair<String, String>>(), api.previews) }
            // Returning from Files can start a foreground status check before the file is read.
            val gate = CompletableDeferred<Unit>()
            compose.runOnUiThread {
                api.statusGate = gate
                model.subscriptionImport.refresh()
            }
            try {
                deliver(1, second)
                compose.waitUntil(10_000) { model.subscriptionImport.state.value.job?.draft == true }
            } finally {
                gate.complete(Unit)
            }
            compose.onNodeWithText("Fixture podcast").assertIsDisplayed()
            compose.runOnIdle {
                val token = if (switchAccount) "second-token" else "fixture-token"
                assertNotEquals(requests.first(), requests.last())
                assertEquals(listOf(token to second.readText()), api.previews)
                assertEquals(0, api.mutations)
            }
        } finally { first.delete(); second.delete() }
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
    private fun retryWithLostResponse(): ImportJob {
        val items = listOf("Podcast", "Publication").mapIndexed { index, title ->
            ImportItem(index, title, "example.org", "failed", "Try again later.", selected = true, retryable = true)
        }
        val original = api.review.copy(id = "original", status = "completed", total = 2,
            finished = 2, failed = 2, items = items)
        api.job = original
        open()
        tapImportAction("Retry failed")
        compose.onNodeWithText("Check import status").assertIsEnabled()
        return original
    }

    private fun tapImportAction(label: String) {
        compose.onNodeWithTag("subscription-import").performScrollToNode(hasText(label))
        compose.onNodeWithText(label).assertIsEnabled().performClick()
    }

    @Test fun statusFindsAcceptedRetryAndNextRetryTargetsOnlyRemainingFailure() {
        val original = retryWithLostResponse()
        val accepted = original.copy(id = "accepted", status = "queued", finished = 0, failed = 0,
            items = original.items.map { it.copy(status = "pending", retryable = false) })
        compose.runOnIdle { api.job = accepted }
        tapImportAction("Check import status")
        compose.onNodeWithText("0 of 2 subscriptions checked").assertIsDisplayed()

        compose.runOnIdle {
            api.job = accepted.copy(status = "completed", finished = 2, added = 1, failed = 1,
                items = listOf(accepted.items.first().copy(status = "added"), original.items.last()))
        }
        // The open progress screen polls until this retry finishes.
        compose.waitUntil(15_000) { compose.onAllNodesWithText("Retry failed").fetchSemanticsNodes().isNotEmpty() }
        tapImportAction("Retry failed")
        compose.onNodeWithText("0 of 1 subscriptions checked").assertIsDisplayed()
        compose.runOnIdle {
            assertEquals(listOf("original", "accepted"), api.retries.map { it.jobId })
            assertNotEquals(api.retries.first().requestId, api.retries.last().requestId)
            assertEquals(listOf("Publication"), api.job!!.items.map { it.title })
        }
    }

    @Test fun statusStillShowsOriginalJobAndRetryReusesUnconfirmedRequest() {
        val original = retryWithLostResponse()
        tapImportAction("Check import status")
        compose.onNodeWithText("Check import status").assertDoesNotExist()
        tapImportAction("Retry failed")
        compose.onNodeWithText("0 of 2 subscriptions checked").assertIsDisplayed()
        compose.runOnIdle {
            assertEquals(2, api.retries.size)
            val (first, second) = api.retries
            assertEquals(original.id, first.jobId)
            assertTrue(first.requestId.isNotBlank())
            assertEquals(first, second)
        }
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
