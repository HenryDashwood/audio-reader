package com.henrydashwood.magpie

import android.content.Intent
import android.content.ClipData
import android.view.View
import android.view.ViewGroup
import android.webkit.WebView
import androidx.test.espresso.Espresso.onView
import androidx.test.espresso.action.ViewActions.click
import androidx.test.espresso.matcher.ViewMatchers.isAssignableFrom
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
        // MainActivity is singleTask and can survive an earlier share test.
        // Do not let its ViewModel keep the previous test's fake repository.
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        instrumentation.runOnMainSync {
            val monitor = androidx.test.runner.lifecycle.ActivityLifecycleMonitorRegistry.getInstance()
            androidx.test.runner.lifecycle.Stage.entries.filter { it != androidx.test.runner.lifecycle.Stage.DESTROYED }.forEach { stage ->
                monitor.getActivitiesInStage(stage).filterIsInstance<MainActivity>().forEach { it.finish() }
            }
        }
        instrumentation.waitForIdleSync()
        api = Api(); library = AccountLibrary(api, "https://share-${UUID.randomUUID()}.invalid")
        runBlocking(Dispatchers.Main) { library.changeSession("alice") }
        app.libraryOverride = library
        // Hidden page capture never reaches the network in tests: unknown pages are 404s.
        CaptureFixtures.respond = { url ->
            pages[url]?.let {
                if (it.startsWith("{\"errors\":")) android.webkit.WebResourceResponse("application/json", "UTF-8", 400, "Bad Request", emptyMap(), it.byteInputStream())
                else android.webkit.WebResourceResponse("text/html", "UTF-8", it.byteInputStream())
            }
                ?: android.webkit.WebResourceResponse("text/html", "UTF-8", 404, "Not Found", emptyMap(), "".byteInputStream())
        }
    }
    private val pages = mutableMapOf<String, String>()
    private val prose = "This is a complete article about a quiet walk through the garden. The trees provide shade and the birds sing in the branches. ".repeat(12)
    private fun article(url: String) = "<html><head><meta name='viewport' content='width=device-width, initial-scale=1'><title>A quiet walk</title><link rel='canonical' href='$url'></head><body><nav>Site menu</nav><article><h1>A quiet walk</h1><p>$prose</p><p style='display:none'>HIDDEN SECRET</p><p id='late'></p></article><script>setTimeout(function(){document.getElementById('late').textContent='Rendered by script.'}, 200)</script></body></html>"
    private fun substackArticle(url: String) = article(url).replace("</head>", "<script src='https://substackcdn.com/bundle/static/js/main.js'></script></head>")
    @After fun cleanup() {
        CaptureFixtures.respond = null
        scenario?.close()
        runBlocking { library.state.value.owner?.let { owner -> app.articleInbox.pending(owner).forEach { app.articleInbox.remove(owner, it.id) } } }
        app.libraryOverride = null
    }
    private fun launch(text: String = "https://example.com/story", html: String? = null, capture: Boolean = false) {
        val target = Intent().setClassName(app, if (capture) ShareActivity.CAPTURE_PAGE else ShareActivity::class.java.name)
        scenario = ActivityScenario.launch(target.apply {
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
        assertFalse("Browser-supplied HTML is not read again", model.state.value.preparing)
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
        compose.onNodeWithText("Save link only").performScrollTo().performClick()
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
            // The activity monitor fires before its first Compose frame. Wait
            // for that screen before timing the asynchronous queue handoff.
            compose.waitForIdle()
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
    @Test fun linkOnlyShareReadsThePageOutOfSightSoOneSaveKeepsIt() {
        val url = "https://capture-fixture.invalid/hidden"
        pages[url] = article(url)
        launch(url)
        // Saving before the page is read waits for it rather than storing a bare link.
        compose.onNodeWithText("Reading the page…").assertExists()
        compose.onNodeWithText("Save article").performScrollTo().performClick()
        compose.waitUntil(20_000) { model.state.value.saved }
        val stored = runBlocking { app.articleInbox.pending(checkNotNull(library.state.value.owner)) }.single()
        assertEquals(url, stored.url); assertEquals("article", stored.contentFormat); assertEquals("A quiet walk", stored.title)
        assertTrue(stored.html!!.contains("quiet walk")); assertTrue(stored.html.contains("Rendered by script."))
        assertFalse(stored.html.contains("HIDDEN SECRET")); assertFalse(stored.html.contains("Site menu"))
        assertTrue(api.captures.isEmpty())
    }
    @Test fun titleAnchoredCaptureUploadsOnlyTheSpecificArticleIncludingItsEnding() {
        val url = "https://unfamiliar-publisher.example/specific-story"
        val paragraphs = (1..13).map { "Article paragraph $it. $prose" }
        val recommendations = "<p>Unrelated recommendation. $prose</p>".repeat(20)
        pages[url] = "<html><head><title>A quiet walk</title><link rel='canonical' href='$url'></head>" +
            "<body><main><div><div><h1>A quiet walk</h1>" + paragraphs.joinToString("") { "<p>$it</p>" } +
            "</div><section><h3>Related posts</h3>$recommendations</section></div>" +
            "<div><p>Outside feed. $prose</p>$recommendations</div></main></body></html>"
        launch(url)
        compose.waitUntil(20_000) { !model.state.value.preparing }
        compose.onNodeWithText("Save article").performScrollTo().performClick()
        compose.waitUntil(10_000) { model.state.value.saved }
        val stored = runBlocking { app.articleInbox.pending(checkNotNull(library.state.value.owner)) }.single()
        val body = org.jsoup.Jsoup.parse(checkNotNull(stored.html)).body()
        assertEquals(paragraphs.map { it.trim() }, body.select("p").map { it.text() })
        assertFalse(body.text().contains("Unrelated recommendation"))
        assertFalse(body.text().contains("Outside feed"))
        assertEquals("article", stored.contentFormat)
        assertTrue(stored.replaceExisting)
        runBlocking(Dispatchers.Main) {
            api.offline = false
            SavedPreparation(this, library, app.articleInbox).activate(library.state.value.owner, library.state.value.revision)
        }
        assertEquals(stored.html, api.captures.single().html)
        assertTrue(runBlocking { app.articleInbox.pending(checkNotNull(library.state.value.owner)) }.isEmpty())
    }
    @Test fun latePaywallCannotBeSavedFromAnEarlyReadableSnapshot() {
        val url = "https://unfamiliar-publisher.example/story"
        pages[url] = article(url).replace("</body>", "<script>setTimeout(function(){document.body.insertAdjacentHTML('beforeend', '<div role=\"dialog\"><h2>Subscribe to continue reading</h2><a href=\"/subscribe\">Subscribe</a></div>')}, 1200)</script></body>")
        launch(url)
        scenario!!.onActivity { model.save() }
        compose.waitUntil(15_000) { !model.state.value.preparing }
        assertTrue(model.state.value.article!!.requiresWebsiteSignIn)
        assertFalse(model.state.value.saved)
        assertTrue(runBlocking { app.articleInbox.pending(checkNotNull(library.state.value.owner)) }.isEmpty())
        compose.onNodeWithText("Sign in to website").assertExists()
    }
    @Test fun unreadablePagesRequireExplicitLinkOnlyChoice() {
        launch("https://capture-fixture.invalid/missing")
        compose.waitUntil(20_000) { !model.state.value.preparing }
        assertFalse(model.state.value.saved)
        assertFalse(model.state.value.saveRequested)
        assertTrue(runBlocking { app.articleInbox.pending(checkNotNull(library.state.value.owner)) }.isEmpty())
        compose.onNodeWithText("Open page to capture").assertExists()
        compose.onNodeWithText("Save article").assertDoesNotExist()
        compose.onNodeWithText("Save link only").performScrollTo().performClick()
        compose.waitUntil(10_000) { model.state.value.saved }
        assertNull(runBlocking { app.articleInbox.pending(checkNotNull(library.state.value.owner)) }.single().html)
    }
    @Test fun substackSignInRedirectKeepsCookieAndPreviewsArticle() {
        val origin = "https://unknown-publication.example"
        val clean = "$origin/p/the-rise-of-the-hopeful-monsters?open=false"
        val broken = "$clean&open=false"
        val login = "$origin/sign-in"
        pages[login] = "<html><body><script>document.cookie='capture_test=logged_in; Path=/; Secure'; location.replace('$broken');</script></body></html>"
        // Substack's canonical omits its browser-opening parameter.
        pages[clean] = substackArticle(clean.substringBefore('?'))
        pages["$clean&open=false"] = """{"errors":[{"location":"query","param":"open","value":["false","false"],"msg":"Invalid value"}]}"""
        try {
            launch(login, capture = true)
            compose.waitUntil(15_000) { compose.onAllNodes(hasText("Preview article") and isEnabled()).fetchSemanticsNodes().isNotEmpty() }
            compose.onNodeWithText(clean).assertExists()
            scenario!!.onActivity {
                assertTrue(android.webkit.CookieManager.getInstance().getCookie(origin).orEmpty().contains("capture_test=logged_in"))
            }
            compose.onNodeWithText("Preview article").performClick()
            compose.waitUntil(15_000) { !model.state.value.browser }
            assertEquals(clean, model.state.value.article!!.url)
            assertEquals("article", model.state.value.article!!.contentFormat)
            assertTrue(model.state.value.article!!.html!!.contains("quiet walk"))
            compose.onNodeWithText("Save article").performScrollTo().performClick()
            compose.waitUntil(10_000) { model.state.value.saved }
            val stored = runBlocking { app.articleInbox.pending(checkNotNull(library.state.value.owner)) }.single()
            assertEquals("article", stored.contentFormat)
            assertTrue(stored.html!!.contains("quiet walk"))
            assertEquals(stored.html, HttpLibraryApi.captureBody(stored).getString("html"))
            assertTrue(api.captures.isEmpty())
        } finally {
            InstrumentationRegistry.getInstrumentation().runOnMainSync {
                android.webkit.CookieManager.getInstance().setCookie(origin, "capture_test=; Path=/; Max-Age=0; Secure")
            }
        }
    }
    @Test fun hiddenCaptureRepairsSharedSubstackUrl() {
        val clean = "https://another-publication.example/p/story?open=false"
        pages[clean] = substackArticle(clean.substringBefore('?'))
        pages["$clean&open=false"] = """{"errors":[{"location":"query","param":"open","value":["false","false"],"msg":"Invalid value"}]}"""
        launch("$clean&open=false")
        compose.waitUntil(20_000) { !model.state.value.preparing }
        assertEquals(clean, model.state.value.article!!.url)
        assertEquals("article", model.state.value.article!!.contentFormat)
        assertTrue(model.state.value.article!!.html!!.contains("quiet walk"))
    }
    @Test fun unsuccessfulExplicitCaptureStaysInBrowserInsteadOfSilentlySavingALink() {
        val url = "https://capture-fixture.invalid/article"
        pages[url] = article("https://capture-fixture.invalid/different-article")
        launch(url, capture = true)
        compose.waitUntil(15_000) { compose.onAllNodes(hasText("Preview article") and isEnabled()).fetchSemanticsNodes().isNotEmpty() }
        compose.onNodeWithText("Preview article").performClick()
        compose.waitUntil(15_000) { compose.onAllNodesWithText("Use link instead").fetchSemanticsNodes().isNotEmpty() }
        compose.onNodeWithText("Magpie could not match this page to its article address. Reload the page and try again.").assertExists()
        assertTrue(model.state.value.browser)
        compose.onNodeWithText("Save article").assertDoesNotExist()
        assertTrue(runBlocking { app.articleInbox.pending(checkNotNull(library.state.value.owner)) }.isEmpty())
        compose.onNodeWithText("Use link instead").performClick()
        assertFalse(model.state.value.browser)
        assertNull(model.state.value.article!!.html)
        compose.onNodeWithText("Only the link was captured. Magpie will try to fetch the article, but pages that require a website sign-in may not be readable.").assertExists()
    }
    @Test fun substackAppRedirectCapturesTextThroughTheSavedUploadPayload() {
        val canonical = "https://www.razibkhan.com/p/land-acknowledgement-greenland-edition"
        val url = "$canonical?utm_campaign=posts-open-in-app&triedRedirect=true"
        pages[url] = substackArticle(canonical)
        launch(url, capture = true)
        compose.waitUntil(15_000) { compose.onAllNodes(hasText("Preview article") and isEnabled()).fetchSemanticsNodes().isNotEmpty() }
        compose.onNodeWithText("Preview article").performClick()
        compose.waitUntil(15_000) { !model.state.value.browser }
        compose.onNodeWithText("Save article").performScrollTo().performClick()
        compose.waitUntil(10_000) { model.state.value.saved }
        val stored = runBlocking { app.articleInbox.pending(checkNotNull(library.state.value.owner)) }.single()
        assertEquals(url, stored.url)
        assertEquals("article", stored.contentFormat)
        assertTrue(stored.html!!.contains("quiet walk"))
        assertEquals(stored.html, HttpLibraryApi.captureBody(stored).getString("html"))
    }
    @Test fun customDomainSubstackCapturesTextThroughTheSavedUploadPayload() {
        val canonical = "https://www.astralcodexten.com/p/lines-composed-in-a-fake-sequoia"
        val url = "$canonical?utm_campaign=posts-open-in-app&triedRedirect=true"
        pages[url] = substackArticle(canonical)
        launch(url, capture = true)
        compose.waitUntil(15_000) { compose.onAllNodes(hasText("Preview article") and isEnabled()).fetchSemanticsNodes().isNotEmpty() }
        compose.onNodeWithText("Preview article").performClick()
        compose.waitUntil(15_000) { !model.state.value.browser }
        compose.onNodeWithText("Save article").performScrollTo().performClick()
        compose.waitUntil(10_000) { model.state.value.saved }
        val stored = runBlocking { app.articleInbox.pending(checkNotNull(library.state.value.owner)) }.single()
        assertEquals(url, stored.url)
        assertEquals("article", stored.contentFormat)
        assertTrue(stored.html!!.contains("quiet walk"))
        assertEquals(stored.html, HttpLibraryApi.captureBody(stored).getString("html"))
    }
    @Test fun insecureLinksAreNotOpenedInTheHiddenBrowser() {
        launch("http://example.com/plain")
        assertFalse(model.state.value.preparing)
        compose.onNodeWithText("Reading the page…").assertDoesNotExist()
    }
    @Test fun ordinaryShareOffersExplicitWebsiteCapture() {
        val url = "https://capture-fixture.invalid/article"
        pages[url] = article(url)
        launch(url)
        compose.waitUntil(15_000) { !model.state.value.preparing }
        compose.onNodeWithText("Sign in or capture page").performScrollTo().performClick()
        assertTrue(model.state.value.browser)
        assertFalse(model.state.value.preparing)
        compose.onNodeWithText("Preview article").assertExists()
    }
    @Test fun viewportSizedSignInDialogStaysInsideTheBrowser() {
        val url = "https://membership-fixture.invalid/story"
        pages[url] = """<html><head><meta name='viewport' content='width=device-width, initial-scale=1'>
            <style>body{margin:0}#sheet{display:none;position:fixed;inset:auto 0 0;height:min(calc(100dvh - env(safe-area-inset-top)),100dvh);overflow:auto;background:white}input{display:block}</style>
            </head><body><button onclick="document.getElementById('sheet').style.display='block'">Join for free</button>
            <main style='height:5000px'><h1>A quiet walk</h1><p>$prose</p></main>
            <div id='sheet' role='dialog'><h2>Sign in</h2><label>Email<input id='email' type='email'></label></div></body></html>"""
        launch(url, capture = true)
        compose.waitUntil(15_000) { compose.onAllNodes(hasText("Preview article") and isEnabled()).fetchSemanticsNodes().isNotEmpty() }
        var geometry: JSONObject? = null
        scenario!!.onActivity { activity ->
            findWebView(activity.window.decorView)!!.evaluateJavascript("""
                document.querySelector('button').click();
                JSON.stringify({height:document.getElementById('sheet').getBoundingClientRect().height,
                  top:document.getElementById('sheet').getBoundingClientRect().top,
                  input:document.getElementById('email').getBoundingClientRect().bottom, viewport:innerHeight})
            """.trimIndent()) { geometry = JSONObject(org.json.JSONTokener(it).nextValue() as String) }
        }
        compose.waitUntil(10_000) { geometry != null }
        val measured = checkNotNull(geometry)
        assertTrue(measured.toString(), measured.getDouble("height") > measured.getDouble("viewport") * 0.9)
        assertTrue(measured.toString(), measured.getDouble("top") >= 0)
        assertTrue(measured.toString(), measured.getDouble("input") < measured.getDouble("viewport"))
    }
    @Test fun clientSideSignInNavigationUpdatesTheCaptureAddress() {
        val url = "https://membership-fixture.invalid/story"
        pages[url] = article(url)
        launch(url, capture = true)
        compose.waitUntil(15_000) { compose.onAllNodes(hasText("Preview article") and isEnabled()).fetchSemanticsNodes().isNotEmpty() }
        scenario!!.onActivity { activity ->
            findWebView(activity.window.decorView)!!.evaluateJavascript("history.pushState({}, '', '/login'); document.body.innerHTML='<h1>Sign in</h1><input type=email>'", null)
        }
        compose.waitUntil(10_000) { compose.onAllNodesWithText("https://membership-fixture.invalid/login").fetchSemanticsNodes().isNotEmpty() }
        compose.onNodeWithText(url).assertDoesNotExist()
        compose.onNodeWithText("Preview article").performClick()
        compose.waitUntil(10_000) { compose.onAllNodesWithText("Use link instead").fetchSemanticsNodes().isNotEmpty() }
        assertNull(model.state.value.article?.html)
        assertTrue(runBlocking { app.articleInbox.pending(checkNotNull(library.state.value.owner)) }.isEmpty())
    }
    private fun launchPopupFixture() {
        val url = "https://publisher-fixture.invalid/story"
        val login = "https://identity-fixture.invalid/login"
        pages[url] = article(url).replace("</body>", """
            <button style='position:fixed;inset:0;width:100%;height:100%' onclick="window.open('$login','signin')">Sign in</button>
            <script>addEventListener('message', function(event) {
              if(event.origin === 'https://identity-fixture.invalid' && event.data === 'fixture-complete') {
                document.querySelector('article').insertAdjacentHTML('beforeend','<p>Returned from the separate sign-in window.</p>');
                document.querySelector('button').remove();
              }
            });</script></body>
        """.trimIndent())
        pages[login] = """<html><head><meta name='viewport' content='width=device-width, initial-scale=1'></head>
            <body><button style='position:fixed;inset:0;width:100%;height:100%'
            onclick="window.opener.postMessage('fixture-complete','https://publisher-fixture.invalid');window.close()">Return to publisher</button></body></html>"""
        launch(url, capture = true)
        compose.waitUntil(15_000) { compose.onAllNodes(hasText("Preview article") and isEnabled()).fetchSemanticsNodes().isNotEmpty() }
        // A real touch is required: JavaScript-created clicks are not a user gesture.
        onView(isAssignableFrom(WebView::class.java)).perform(click())
        compose.waitUntil(15_000) { compose.onAllNodesWithText(login).fetchSemanticsNodes().isNotEmpty() }
        compose.onNodeWithText("Website window").assertExists()
        compose.onNodeWithText("Preview article").assertIsNotEnabled()
        scenario!!.onActivity { activity ->
            assertEquals(View.INVISIBLE, findWebView(activity.window.decorView)!!.visibility)
        }
    }
    @Test fun signInPopupReturnsToItsPreservedOpenerWithoutCapturingCredentials() {
        launchPopupFixture()
        onView(org.hamcrest.Matchers.allOf(isAssignableFrom(WebView::class.java),
            androidx.test.espresso.matcher.ViewMatchers.withParent(isAssignableFrom(android.widget.FrameLayout::class.java)),
            org.hamcrest.Matchers.`is`(findPopup()))).perform(click())
        compose.waitUntil(15_000) { compose.onAllNodesWithText("Close window").fetchSemanticsNodes().isEmpty() }
        compose.onNodeWithText("https://publisher-fixture.invalid/story").assertExists()
        compose.onNodeWithText("Preview article").performClick()
        compose.waitUntil(15_000) { !model.state.value.browser }
        assertTrue(model.state.value.article!!.html!!.contains("Returned from the separate sign-in window."))
        assertFalse(model.state.value.article!!.html!!.contains("Return to publisher"))
        assertTrue(api.captures.isEmpty())
        assertTrue(runBlocking { app.articleInbox.pending(checkNotNull(library.state.value.owner)) }.isEmpty())
    }
    @Test fun closingSignInPopupKeepsTheOriginalPageAvailable() {
        launchPopupFixture()
        compose.onNodeWithText("Close window").performClick()
        compose.onNodeWithText("https://publisher-fixture.invalid/story").assertExists()
        compose.onNodeWithText("Preview article").assertIsEnabled()
        compose.onNodeWithText("Website window").assertDoesNotExist()
        scenario!!.onActivity { activity ->
            assertEquals(View.VISIBLE, findWebView(activity.window.decorView)!!.visibility)
        }
        assertNull(model.state.value.article?.html)
        assertTrue(runBlocking { app.articleInbox.pending(checkNotNull(library.state.value.owner)) }.isEmpty())
    }
    private fun findPopup(): WebView {
        var child: WebView? = null
        scenario!!.onActivity { activity ->
            val root = findWebView(activity.window.decorView)!!
            val holder = root.parent as ViewGroup
            child = holder.getChildAt(holder.childCount - 1) as WebView
        }
        return checkNotNull(child)
    }
    @Test fun ghostPaywallOffersSignInAndSavesOnlyAfterUnlockedCapture() {
        val url = "https://ghost-fixture.invalid/members-story/"
        val login = "https://ghost-fixture.invalid/signin/"
        pages[url] = article(url).replace("</head>", "<meta name='generator' content='Ghost 6.70'></head>")
            .replace("</body>", "<div class='single-content'><section class='single-cta'><h2>This post is for subscribers only</h2><a data-portal='signin' href='$login'>Sign in</a></section></div></body>")
        launch(url)
        scenario!!.onActivity { model.save() }
        compose.waitUntil(15_000) { model.state.value.article?.requiresWebsiteSignIn == true }
        assertFalse(model.state.value.saved)
        assertFalse(model.state.value.saveRequested)
        assertTrue(runBlocking { app.articleInbox.pending(checkNotNull(library.state.value.owner)) }.isEmpty())
        compose.onNodeWithText("Save article").assertDoesNotExist()
        compose.onNodeWithText("Sign in to website").performClick()
        compose.waitUntil(15_000) { compose.onAllNodes(hasText("Preview article") and isEnabled()).fetchSemanticsNodes().isNotEmpty() }
        compose.onNodeWithText("Preview article").performClick()
        compose.waitUntil(15_000) { compose.onAllNodesWithText(CaptureIssue.WEBSITE_SIGN_IN.message).fetchSemanticsNodes().isNotEmpty() }
        assertTrue(model.state.value.browser)
        pages[url] = article(url)
        pages[login] = "<html><body><script>location.replace('$url');</script></body></html>"
        scenario!!.onActivity { findWebView(it.window.decorView)!!.evaluateJavascript("document.querySelector('[data-portal]').click()", null) }
        compose.waitUntil(15_000) { compose.onAllNodes(hasText("Preview article") and isEnabled()).fetchSemanticsNodes().isNotEmpty() }
        compose.onNodeWithText("Preview article").performClick()
        compose.waitUntil(15_000) { !model.state.value.browser }
        compose.onNodeWithText("Save article").performScrollTo().performClick()
        compose.waitUntil(10_000) { model.state.value.saved }
        val stored = runBlocking { app.articleInbox.pending(checkNotNull(library.state.value.owner)) }.single()
        assertEquals("article", stored.contentFormat)
        assertTrue(stored.html!!.contains("quiet walk"))
        assertFalse(stored.html.contains("subscribers only"))
    }
    @Test fun browserExtractsVisibleArticleForReviewWithoutUploadingAndRejectsStaleIdentity() {
        // Saved opens capture directly; ordinary shares also expose an explicit browser action.
        launch("https://capture-fixture.invalid/article", capture = true)
        compose.onNodeWithText("Preview article").assertExists()
        compose.waitForIdle()
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
        assertFalse(article.html.contains("HIDDEN SECRET")); assertTrue(api.captures.isEmpty())
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
