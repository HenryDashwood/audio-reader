package com.henrydashwood.magpie

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.view.accessibility.AccessibilityEvent
import androidx.activity.compose.LocalActivityResultRegistryOwner
import androidx.activity.compose.setContent
import androidx.activity.result.*
import androidx.activity.result.contract.*
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createEmptyComposeRule
import androidx.core.app.ActivityOptionsCompat
import androidx.lifecycle.ViewModelProvider
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import androidx.test.platform.app.InstrumentationRegistry
import com.henrydashwood.magpie.data.*
import com.henrydashwood.magpie.playback.PlaybackService
import com.henrydashwood.magpie.ui.MagpieApp
import com.henrydashwood.magpie.ui.MagpieTheme
import java.io.File
import java.util.concurrent.CopyOnWriteArrayList
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import org.junit.*
import org.junit.Assert.*

class SubscriptionExportPickerTest {
    @get:Rule val compose = createEmptyComposeRule()
    private val app get() = ApplicationProvider.getApplicationContext<MagpieTestApplication>()
    private lateinit var api: Api
    private lateinit var library: AccountLibrary
    private lateinit var scenario: ActivityScenario<MainActivity>

    private class Api : LibraryApi, SubscriptionExportApi {
        val startedB = CompletableDeferred<Unit>()
        val releaseB = CompletableDeferred<Unit>()
        fun xml(token: String) = """<opml version="2.0"><body><outline xmlUrl="https://feeds.invalid/$token"/></body></opml>"""
        override suspend fun exportSubscriptions(token: String): String {
            if (token == "B") {
                startedB.complete(Unit)
                releaseB.await()
            }
            return xml(token)
        }
        override suspend fun userId(token: String) = token
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
        api = Api()
        library = AccountLibrary(api, "https://fixture.invalid")
        runBlocking(Dispatchers.Main) { library.changeSession("A") }
        app.libraryOverride = library
        scenario = ActivityScenario.launch(MainActivity::class.java)
    }
    @After fun finish() {
        scenario.close()
        app.stopService(Intent(app, PlaybackService::class.java))
        app.libraryOverride = null
    }

    private enum class OldResult { Writable, Unwritable, Cancelled }

    @Test fun lateSaveWhileBPrepares() = checkReplacement(OldResult.Writable, false)
    @Test fun lateFailureWhileBPrepares() = checkReplacement(OldResult.Unwritable, false)
    @Test fun lateCancellationWhileBPrepares() = checkReplacement(OldResult.Cancelled, false)
    @Test fun lateSaveWhileBChoosesDestination() = checkReplacement(OldResult.Writable, true)
    @Test fun lateFailureWhileBChoosesDestination() = checkReplacement(OldResult.Unwritable, true)
    @Test fun lateCancellationWhileBChoosesDestination() = checkReplacement(OldResult.Cancelled, true)

    private fun checkReplacement(oldResult: OldResult, bPickerOpen: Boolean) {
        val requests = CopyOnWriteArrayList<Int>()
        val registry = object : ActivityResultRegistry() {
            override fun <I, O> onLaunch(requestCode: Int, contract: ActivityResultContract<I, O>,
                input: I, options: ActivityOptionsCompat?) {
                val intent = contract.createIntent(app, input)
                assertEquals(Intent.ACTION_CREATE_DOCUMENT, intent.action)
                assertEquals("text/x-opml", intent.type)
                requests.add(requestCode)
            }
        }
        val registryOwner = object : ActivityResultRegistryOwner { override val activityResultRegistry = registry }
        lateinit var model: MagpieModel
        scenario.onActivity { activity ->
            model = ViewModelProvider(activity)[MagpieModel::class.java]
            activity.setContent {
                CompositionLocalProvider(LocalActivityResultRegistryOwner provides registryOwner) {
                    MagpieTheme { MagpieApp(model) }
                }
            }
        }

        fun startExport() {
            compose.onNodeWithTag("settings-list").performScrollToNode(hasText("Export subscriptions"))
            compose.onNodeWithText("Export subscriptions").performClick()
            compose.onNodeWithText("Export OPML file").assertIsEnabled().performClick()
        }
        fun openBPicker() {
            api.releaseB.complete(Unit)
            compose.waitUntil(10_000) { requests.size == 2 }
            assertEquals(api.xml("B"), model.pendingSubscriptionExport.value?.xml)
        }
        fun deliver(request: Int, uri: Uri?) {
            compose.runOnUiThread {
                registry.dispatchResult(request, if (uri == null) Activity.RESULT_CANCELED else Activity.RESULT_OK,
                    uri?.let { Intent().setData(it) })
            }
        }

        val directory = java.nio.file.Files.createTempDirectory(app.cacheDir.toPath(), "opml").toFile()
        val aFile = File(directory, "A.opml")
        val bFile = File(directory, "B.opml")
        val success = "Subscriptions exported."
        val failure = "The file couldn’t be saved. Please try again."
        val automation = InstrumentationRegistry.getInstrumentation().uiAutomation
        val announcements = CopyOnWriteArrayList<String>()
        try {
            compose.onNodeWithText("Settings").performClick()
            startExport()
            compose.waitUntil(10_000) { requests.size == 1 }
            assertEquals(api.xml("A"), model.pendingSubscriptionExport.value?.xml)

            runBlocking(Dispatchers.Main) { library.changeSession("B") }
            compose.waitUntil(10_000) {
                model.pendingSubscriptionExport.value == null &&
                    compose.onAllNodesWithText("Export OPML file").fetchSemanticsNodes().isEmpty()
            }
            startExport()
            compose.waitUntil(10_000) { api.startedB.isCompleted }
            if (bPickerOpen) openBPicker()

            automation.setOnAccessibilityEventListener { event ->
                val text = event.text.joinToString() + " " + event.contentDescription
                @Suppress("DEPRECATION")
                val explicit = event.eventType == AccessibilityEvent.TYPE_ANNOUNCEMENT
                if (event.packageName == app.packageName && (explicit || success in text || failure in text)) {
                    announcements.add(event.toString())
                }
            }
            deliver(requests.first(), when (oldResult) {
                OldResult.Writable -> Uri.fromFile(aFile)
                OldResult.Unwritable -> Uri.fromFile(File(directory, "missing/A.opml"))
                OldResult.Cancelled -> null
            })
            if (!bPickerOpen) openBPicker()
            compose.waitForIdle()
            automation.waitForIdle(500, 5_000)
            assertEquals(api.xml("B"), model.pendingSubscriptionExport.value?.xml)
            assertFalse(aFile.exists())
            compose.onNodeWithText(success).assertDoesNotExist()
            compose.onNodeWithText(failure).assertDoesNotExist()
            assertTrue(announcements.toString(), announcements.isEmpty())
            automation.setOnAccessibilityEventListener(null)

            deliver(requests.last(), Uri.fromFile(bFile))
            compose.waitUntil(10_000) { compose.onAllNodesWithText(success).fetchSemanticsNodes().isNotEmpty() }
            assertEquals(api.xml("B"), bFile.readText())
            assertFalse(aFile.exists())
            assertEquals(2, requests.size)
            assertNull(model.pendingSubscriptionExport.value)
        } finally {
            automation.setOnAccessibilityEventListener(null)
            api.releaseB.complete(Unit)
            directory.deleteRecursively()
        }
    }
}
