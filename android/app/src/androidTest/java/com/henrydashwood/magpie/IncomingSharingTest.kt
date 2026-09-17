package com.henrydashwood.magpie

import android.content.Intent
import android.content.ClipData
import android.view.View
import android.view.ViewGroup
import android.webkit.WebView
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
import com.henrydashwood.magpie.sharing.*
import com.henrydashwood.magpie.ui.MagpieTheme
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import org.junit.*
import org.junit.Assert.*
import java.io.File
import java.io.IOException
import java.util.UUID

class IncomingSharingTest {
    @get:Rule val compose = createEmptyComposeRule()
    private val app get() = ApplicationProvider.getApplicationContext<MagpieTestApplication>()
    private lateinit var library: AccountLibrary
    private lateinit var api: Api
    private var scenario: ActivityScenario<ShareActivity>? = null
    private lateinit var model: ShareModel
    private class Api : LibraryApi, SavedArticleApi {
        val captures = mutableListOf<PendingArticle>()
        val rows = mutableListOf<RemoteEpisode>()
        var offline = true
        override suspend fun userId(token: String) = token
        override suspend fun feeds(token: String) = emptyList<LibraryFeed>()
        override suspend fun latest(token: String) = emptyList<RemoteEpisode>()
        override suspend fun saved(token: String) = rows.toList()
        override suspend fun episodes(token: String, feedId: String, query: String) = emptyList<RemoteEpisode>()
        override suspend fun search(token: String, query: String) = emptyList<RemoteEpisode>()
        override suspend fun text(token: String, episodeId: Int, contentId: Int?) = RemoteText(episodeId, contentId, "Story", "<p>Story</p>", 1)
        override suspend fun save(token: String, episodeId: Int?, url: String?) = error("not used")
        override suspend fun remove(token: String, episodeId: Int) {}
        override suspend fun played(token: String, episodeId: Int, played: Boolean) {}
        override suspend fun clearLatest(token: String) {}
        override suspend fun subscribe(token: String, url: String) = error("not used")
        override suspend fun position(token: String, episodeId: Int, seconds: Double, completed: Boolean) {}
        override suspend fun capture(token: String, article: PendingArticle): RemoteEpisode {
            if (offline) throw IOException()
            captures += article
            return RemoteEpisode(42, article.title ?: "Shared story", link = article.url, contentId = 9).also { row ->
                rows.removeAll { it.id == row.id }; rows += row
            }
        }
        override suspend fun retrySaved(token: String, episodeId: Int) = error("not used")
        override suspend fun replaceSaved(token: String, episodeId: Int) = error("not used")
    }
    @Before fun setup() {
        api = Api(); library = AccountLibrary(api, "https://share-${UUID.randomUUID()}.invalid")
        runBlocking(Dispatchers.Main) { library.changeSession("alice") }
        app.libraryOverride = library
    }
    @After fun cleanup() {
        scenario?.close()
        runBlocking { library.state.value.owner?.let { owner -> app.articleInbox.pending(owner).forEach { app.articleInbox.remove(owner, it.id) } } }
        app.libraryOverride = null
    }
    private fun launch(text: String = "https://example.com/story", html: String? = null) {
        scenario = ActivityScenario.launch(Intent(app, ShareActivity::class.java).apply {
            action = Intent.ACTION_SEND; type = if (html == null) "text/plain" else "text/html"
            putExtra(Intent.EXTRA_TEXT, text); putExtra(Intent.EXTRA_SUBJECT, "Shared story")
            if (html != null) putExtra(Intent.EXTRA_HTML_TEXT, html)
        })
        scenario!!.onActivity { model = ViewModelProvider(it)[ShareModel::class.java] }
        compose.waitUntil(10_000) { !model.state.value.busy }
    }
    @Test fun confirmationRecreationAndOfflineQueuePreserveHtmlUntilSuccessfulSync() {
        val html = "<article><h1>Shared story</h1><p>Shared browser content.</p></article>"
        launch(html = html)
        val owner = checkNotNull(library.state.value.owner)
        assertTrue(runBlocking { app.articleInbox.pending(owner) }.isEmpty())
        scenario!!.recreate()
        compose.onNodeWithText("Save article").performScrollTo().performClick()
        compose.waitUntil(10_000) { model.state.value.saved }
        val stored = runBlocking { ArticleInboxStore(app, "magpie_test_account_captures").pending(owner) }.single()
        assertEquals(html, stored.html); assertEquals("page", stored.contentFormat); assertTrue(stored.replaceExisting)
        assertTrue(api.captures.isEmpty())
        scenario!!.recreate(); compose.onNodeWithText("Saved to Magpie").assertIsDisplayed()
        val body = HttpLibraryApi.captureBody(stored)
        assertEquals(html, body.getString("html")); assertEquals(stored.savedAt, body.getString("saved_at"))
        runBlocking(Dispatchers.Main) {
            assertTrue(runCatching { library.captureSaved(stored, library.state.value.revision) }.isFailure)
            assertEquals(stored.id, app.articleInbox.pending(owner).single().id)
            api.offline = false
            library.captureSaved(stored, library.state.value.revision)
            app.articleInbox.remove(owner, stored.id)
        }
        assertEquals(html, api.captures.single().html)
        assertEquals(42, library.state.value.items.single().episodeId)
    }
    @Test fun cancelAndNewIntentsCannotAccidentallySaveOrReuseOldContent() {
        launch(html = "<p>Old content</p>")
        scenario!!.onActivity { it.onNewIntentForTest(Intent(Intent.ACTION_SEND).apply { type = "text/html"; putExtra(Intent.EXTRA_TEXT, "https://example.com/second") }) }
        compose.waitUntil(10_000) { model.state.value.article?.url?.endsWith("second") == true }
        assertNull(model.state.value.article!!.html)
        compose.onNodeWithText("Cancel").performScrollTo().performClick()
        assertTrue(runBlocking { app.articleInbox.pending(checkNotNull(library.state.value.owner)) }.isEmpty())
        assertTrue(api.captures.isEmpty())
    }
    @Test fun accountSwitchRequiresFreshConfirmationAndNeverMovesOldCaptures() {
        launch()
        val alice = checkNotNull(library.state.value.owner)
        runBlocking(Dispatchers.Main) { library.changeSession("bob") }
        compose.waitUntil(10_000) { model.state.value.accountChanged }
        compose.onNodeWithText("Save article").assertDoesNotExist()
        scenario!!.onActivity { model.save() }
        assertTrue(runBlocking { app.articleInbox.pending(alice) }.isEmpty())
        compose.onNodeWithText("Review again").performClick()
        compose.onNodeWithText("Save article").performScrollTo().performClick()
        compose.waitUntil(10_000) { model.state.value.saved }
        assertTrue(runBlocking { app.articleInbox.pending(alice) }.isEmpty())
        assertEquals(1, runBlocking { app.articleInbox.pending(checkNotNull(library.state.value.owner)) }.size)
    }
    @Test fun signedOutInvalidAndClipSharesHaveExplicitOutcomes() {
        runBlocking(Dispatchers.Main) { library.changeSession(null) }
        launch()
        compose.onNodeWithText("Save article").assertDoesNotExist()
        compose.onNodeWithText("Open Magpie").assertExists()
        assertEquals("https://example.com/clip", SharedArticles.fromIntent(Intent(Intent.ACTION_SEND).apply {
            type = "text/plain"; clipData = ClipData.newPlainText("link", "https://example.com/clip")
        }).url)
        scenario!!.onActivity { it.onNewIntentForTest(Intent(Intent.ACTION_SEND).apply { type = "text/plain"; putExtra(Intent.EXTRA_TEXT, "content://private/data") }) }
        compose.waitUntil(10_000) { model.state.value.error != null }
        compose.onNodeWithText("Share an http:// or https:// web link to save an article.").assertIsDisplayed()
        assertNull(model.state.value.article)
    }
    @Test fun openingMagpieToSignInKeepsTheUnconfirmedShareAvailable() {
        runBlocking(Dispatchers.Main) { library.changeSession(null) }
        launch(html = "<p>Keep this unconfirmed content.</p>")
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val monitor = instrumentation.addMonitor(MainActivity::class.java.name, null, false)
        try {
            compose.onNodeWithText("Open Magpie").performScrollTo().performClick()
            val main = checkNotNull(monitor.waitForActivityWithTimeout(10_000))
            runBlocking(Dispatchers.Main) { library.changeSession("alice") }
            instrumentation.runOnMainSync { main.finish() }
            compose.waitUntil(10_000) { scenario!!.state == androidx.lifecycle.Lifecycle.State.RESUMED }
            compose.onNodeWithText("Review again").performScrollTo().performClick()
            assertEquals("<p>Keep this unconfirmed content.</p>", model.state.value.article!!.html)
            assertTrue(runBlocking { app.articleInbox.pending(checkNotNull(library.state.value.owner)) }.isEmpty())
        } finally { instrumentation.removeMonitor(monitor) }
    }
    @Test fun openMagpieAfterConfirmationPreparesTheQueuedArticleInSaved() {
        api.offline = false
        launch(html = "<article><p>Confirmed shared content.</p></article>")
        compose.onNodeWithText("Save article").performScrollTo().performClick()
        compose.waitUntil(10_000) { model.state.value.saved }
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val monitor = instrumentation.addMonitor(MainActivity::class.java.name, null, false)
        var main: android.app.Activity? = null
        try {
            compose.onNodeWithText("Open Magpie").performScrollTo().performClick()
            main = checkNotNull(monitor.waitForActivityWithTimeout(10_000))
            compose.waitUntil(10_000) { library.state.value.items.any { it.episodeId == 42 } }
            compose.onNodeWithText("Shared story").assertIsDisplayed()
            compose.waitUntil(10_000) { runBlocking { app.articleInbox.pending(checkNotNull(library.state.value.owner)) }.isEmpty() }
            assertEquals(1, api.captures.size)
            assertEquals("<article><p>Confirmed shared content.</p></article>", api.captures.single().html)
        } finally {
            main?.let { activity -> instrumentation.runOnMainSync { activity.finish() } }
            instrumentation.removeMonitor(monitor)
        }
    }
    @Test fun aNewerQueuedCaptureSurvivesAcknowledgementOfAnOlderRequest() = runBlocking {
        val owner = checkNotNull(library.state.value.owner)
        val first = PendingArticle(url = "https://example.com/story", html = "<p>Earlier offline copy</p>", replaceExisting = true)
        app.articleInbox.add(owner, first)
        val newer = SharedArticle(first.url, "New", "<p>New text</p>").pending()
        app.articleInbox.add(owner, newer)
        assertEquals(listOf(first.html, newer.html), app.articleInbox.pending(owner).map { it.html })
        app.articleInbox.remove(owner, first.id)
        val restored = ArticleInboxStore(app, "magpie_test_account_captures").pending(owner).single()
        assertEquals(newer.id, restored.id); assertEquals(first.savedAt, restored.savedAt); assertEquals(newer.html, restored.html)
        // A legacy URL-only add cannot discard an explicit content capture.
        app.articleInbox.add(owner, PendingArticle(url = first.url))
        assertEquals(newer.id, app.articleInbox.pending(owner).single().id)
    }
    @Test fun browserExtractsVisibleArticleForReviewWithoutUploadingAndRejectsStaleIdentity() {
        launch("https://capture-fixture.invalid/article")
        compose.onNodeWithText("Capture page").performScrollTo().performClick()
        compose.onNodeWithText("Preview article").assertExists()
        compose.waitForIdle()
        val prose = "This is a complete article about a quiet walk through the garden. The trees provide shade and the birds sing in the branches. ".repeat(12)
        val html = "<html><head><meta name='viewport' content='width=device-width, initial-scale=1'><title>A quiet walk</title><link rel='canonical' href='https://capture-fixture.invalid/article'></head><body><article><h1>A quiet walk</h1><p>$prose</p><p style='display:none'>HIDDEN SECRET</p></article></body></html>"
        scenario!!.onActivity { activity ->
            val view = findWebView(activity.window.decorView)!!
            assertFalse(view.settings.allowFileAccess); assertFalse(view.settings.allowContentAccess)
            // Serve a normal document navigation. loadDataWithBaseURL can leave
            // newer WebViews waiting on the previous invalid-host navigation.
            val client = view.webViewClient
            view.stopLoading()
            view.webViewClient = object : android.webkit.WebViewClient() {
                override fun shouldInterceptRequest(view: WebView, request: android.webkit.WebResourceRequest): android.webkit.WebResourceResponse? =
                    if (request.url.toString() == "https://capture-fixture.invalid/article")
                        android.webkit.WebResourceResponse("text/html", "UTF-8", html.byteInputStream())
                    else client.shouldInterceptRequest(view, request)
                override fun onPageStarted(view: WebView, url: String, favicon: android.graphics.Bitmap?) = client.onPageStarted(view, url, favicon)
                override fun onPageFinished(view: WebView, url: String) = client.onPageFinished(view, url)
                override fun onReceivedError(view: WebView, request: android.webkit.WebResourceRequest, error: android.webkit.WebResourceError) =
                    client.onReceivedError(view, request, error)
                override fun shouldOverrideUrlLoading(view: WebView, request: android.webkit.WebResourceRequest) = client.shouldOverrideUrlLoading(view, request)
            }
            view.loadUrl("https://capture-fixture.invalid/article")
        }
        // WebView loading is asynchronous; wait until the enabled action is exposed.
        try {
            compose.waitUntil(15_000) { compose.onAllNodes(hasText("Preview article") and isEnabled()).fetchSemanticsNodes().isNotEmpty() }
        } catch (failure: ComposeTimeoutException) {
            screenshot("capture-browser-failure")
            throw AssertionError(compose.onRoot().printToString(), failure)
        }
        screenshot("capture-browser")
        compose.onNodeWithText("Preview article").performClick()
        try {
            compose.waitUntil(15_000) { !model.state.value.browser }
        } catch (failure: ComposeTimeoutException) {
            screenshot("capture-extraction-failure")
            throw AssertionError(compose.onRoot().printToString(), failure)
        }
        compose.onNodeWithText("Save article").assertExists()
        screenshot("captured-article-preview")
        val article = model.state.value.article!!
        assertEquals("article", article.contentFormat); assertTrue(article.html!!.contains("quiet walk"))
        assertFalse(article.html!!.contains("HIDDEN SECRET")); assertTrue(api.captures.isEmpty())
        assertTrue(runBlocking { app.articleInbox.pending(checkNotNull(library.state.value.owner)) }.isEmpty())
        val forged = JSONObject().put("url", "https://different.invalid").put("html", "<p>wrong</p>")
        assertTrue(runCatching { decodeCapture(JSONObject.quote(forged.toString()), article.url) }.isFailure)
    }
    @Test fun largeTextDarkShareConfirmationRemainsScrollable() {
        launch(html = "<p>" + "A readable preview. ".repeat(40) + "</p>")
        scenario!!.onActivity { activity -> activity.setContent {
            CompositionLocalProvider(LocalDensity provides Density(activity.resources.displayMetrics.density, 2f)) {
                MagpieTheme(darkTheme = true) { ShareScreen(model, activity::finish, {}) }
            }
        } }
        compose.onNodeWithText("Save article").performScrollTo().assertIsDisplayed()
        screenshot("incoming-share-large-dark")
        compose.onNodeWithText("Cancel").performScrollTo().assertIsDisplayed()
    }
    private fun screenshot(name: String) {
        compose.waitForIdle()
        // Let the compositor present the new screen before taking a device screenshot.
        android.os.SystemClock.sleep(250)
        val bitmap = checkNotNull(InstrumentationRegistry.getInstrumentation().uiAutomation.takeScreenshot())
        val directory = InstrumentationRegistry.getArguments().getString("additionalTestOutputDir")?.let(::File) ?: File(app.filesDir, "screenshots")
        directory.mkdirs()
        File(directory, "$name.png").outputStream().use { bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it) }
    }
    private fun findWebView(view: View): WebView? {
        if (view is WebView) return view
        if (view is ViewGroup) for (i in 0 until view.childCount) findWebView(view.getChildAt(i))?.let { return it }
        return null
    }
    private fun ShareActivity.onNewIntentForTest(intent: Intent) {
        // Exercise actual existing-activity delivery rather than calling the model directly.
        startActivity(intent.setClass(app, ShareActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP))
    }
}
