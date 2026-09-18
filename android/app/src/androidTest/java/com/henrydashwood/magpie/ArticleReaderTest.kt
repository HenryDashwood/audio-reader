package com.henrydashwood.magpie

import android.graphics.Bitmap
import android.view.View
import android.view.ViewGroup
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.*
import androidx.compose.ui.Modifier
import com.henrydashwood.magpie.ui.ArticleFollowControl
import com.henrydashwood.magpie.ui.MiniPlayer
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.unit.Density
import com.henrydashwood.magpie.data.RichArticleSample
import com.henrydashwood.magpie.playback.ArticleReadingPosition
import com.henrydashwood.magpie.ui.ArticleReader
import com.henrydashwood.magpie.ui.ArticleWebView
import com.henrydashwood.magpie.ui.MagpieTheme
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.io.File
import java.util.concurrent.atomic.AtomicReference

class ArticleReaderTest {
    @get:Rule val compose = createAndroidComposeRule<MainActivity>()

    private fun findBrowser(view: View): ArticleWebView? {
        if (view is ArticleWebView) return view
        if (view is ViewGroup) for (i in 0 until view.childCount) findBrowser(view.getChildAt(i))?.let { return it }
        return null
    }

    private fun browser(): ArticleWebView {
        var found: ArticleWebView? = null
        compose.waitUntil(10_000) {
            compose.runOnIdle { found = findBrowser(compose.activity.window.decorView)?.takeIf { it.ready } }
            found != null
        }
        return checkNotNull(found)
    }

    // Explicit app/test evaluation is available; CSP prohibits article-supplied scripts.
    private fun inspect(view: ArticleWebView, expression: String): JSONObject {
        val result = AtomicReference<String?>()
        compose.runOnIdle {
            assertTrue(view.settings.javaScriptEnabled)
            view.evaluateJavascript("JSON.stringify($expression)") { value ->
                result.set(value)
            }
        }
        compose.waitUntil(10_000) { result.get() != null }
        return JSONObject(org.json.JSONTokener(result.get()).nextValue() as String)
    }

    private fun capture(name: String) {
        compose.waitForIdle()
        val instrumentation = androidx.test.platform.app.InstrumentationRegistry.getInstrumentation()
        val bitmap = checkNotNull(instrumentation.uiAutomation.takeScreenshot())
        val supplied = androidx.test.platform.app.InstrumentationRegistry.getArguments().getString("additionalTestOutputDir")
        val directory = (supplied?.let(::File) ?: File(compose.activity.filesDir, "screenshots")).apply { mkdirs() }
        File(directory, "$name.png").outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
        bitmap.recycle()
    }

    @Test fun staticChartsRenderWithCaptionsAndFitTheReader() {
        val svg = """<svg xmlns="http://www.w3.org/2000/svg" width="640" height="420" viewBox="0 0 640 420"
            color="black" style="background:white;color:black"><circle cx="320" cy="210" r="100" fill="#ff5500"/>
            <text x="20" y="40" font-size="24">Chart label</text></svg>"""
        val source = "data:image/svg+xml;base64," + java.util.Base64.getEncoder().encodeToString(svg.toByteArray())
        val item = RichArticleSample.item.copy(title = "An embedded chart", text = "Article text. Usage over time.",
            html = """<p>Article text.</p><figure><img src="$source" alt="Usage chart"><figcaption>Usage over time.</figcaption></figure>""")
        compose.runOnUiThread { compose.activity.setContent { MagpieTheme(darkTheme = true) { ArticleReader(item, "") } } }
        val view = browser()
        compose.waitUntil(10_000) {
            inspect(view, "({loaded: document.querySelector('img').naturalWidth > 0})").getBoolean("loaded")
        }
        val result = inspect(view, """(() => {
            const img = document.querySelector('img'), canvas = document.createElement('canvas');
            canvas.width = 640; canvas.height = 420;
            const ctx = canvas.getContext('2d'); ctx.drawImage(img, 0, 0, 640, 420);
            return {pixel: [...ctx.getImageData(320, 210, 1, 1).data],
                pageFits: document.documentElement.scrollWidth <= innerWidth,
                imageFits: img.getBoundingClientRect().width <= innerWidth,
                alt: img.alt, caption: document.querySelector('figcaption').textContent,
                text: document.querySelector('main').textContent};
        })()""")
        assertEquals("[255,85,0,255]", result.getJSONArray("pixel").toString())
        assertTrue(result.getBoolean("pageFits"))
        assertTrue(result.getBoolean("imageFits"))
        assertEquals("Usage chart", result.getString("alt"))
        assertEquals("Usage over time.", result.getString("caption"))
        assertFalse(result.getString("text").contains("Chart label"))
        capture("article-static-chart")
    }

    @Test fun videoFramesRunInIsolationWithAppReferrerAndFitTheReader() {
        val ran = java.util.concurrent.atomic.AtomicBoolean(false)
        val referrer = AtomicReference<String?>(null)
        lateinit var view: ArticleWebView
        compose.runOnUiThread {
            view = ArticleWebView(compose.activity)
            val delegate = view.webViewClient
            view.webViewClient = object : android.webkit.WebViewClient() {
                override fun onPageFinished(browser: android.webkit.WebView, url: String?) = delegate.onPageFinished(browser, url)
                override fun shouldOverrideUrlLoading(browser: android.webkit.WebView, request: android.webkit.WebResourceRequest) =
                    delegate.shouldOverrideUrlLoading(browser, request)
                override fun shouldInterceptRequest(browser: android.webkit.WebView, request: android.webkit.WebResourceRequest): android.webkit.WebResourceResponse {
                    val player = request.url.path?.startsWith("/embed/") == true
                    if (player) referrer.set(request.requestHeaders.entries.firstOrNull { it.key.equals("Referer", true) }?.value)
                    if (request.url.path == "/script-ran") ran.set(true)
                    val html = if (player) """<html><body><p>Sample video player</p>
                        <script>new Image().src='https://www.youtube-nocookie.com/script-ran';</script></body></html>""" else ""
                    return android.webkit.WebResourceResponse("text/html", "UTF-8", html.byteInputStream())
                }
            }
            val item = RichArticleSample.item.copy(html = """<p>Before</p>
                <iframe src="https://www.youtube.com/embed/Wp7YrZ1H05g" title="A performance"></iframe><p>After</p>""")
            val body = com.henrydashwood.magpie.ui.ArticleDocument.body(item) + "<script>window.articleExecuted = true</script>"
            val html = com.henrydashwood.magpie.ui.ArticleDocument.page(item, body, 20f,
                "#000000", "#FFFFFF", "#555555", "#DDDDDD", "#0000FF", false)
            compose.activity.setContent {
                androidx.compose.ui.viewinterop.AndroidView(factory = { view }, modifier = Modifier.fillMaxSize(), onRelease = { it.release() })
            }
            view.display(html, "", 0, item.text)
        }
        compose.waitUntil(10_000) { ran.get() }
        assertEquals(com.henrydashwood.magpie.ui.ArticleDocument.LOCAL_BASE.substringBefore("/reader/") + "/", referrer.get())
        val result = inspect(view, """({
            articleExecuted: window.articleExecuted === true,
            width: document.querySelector('iframe').getBoundingClientRect().width,
            height: document.querySelector('iframe').getBoundingClientRect().height,
            pageFits: document.documentElement.scrollWidth <= innerWidth,
            fallback: document.querySelector('[data-hearful-metadata] a').textContent
        })""")
        assertFalse(result.getBoolean("articleExecuted"))
        assertTrue(result.getBoolean("pageFits"))
        assertTrue(result.getDouble("width") >= 200)
        assertTrue(result.getDouble("height") >= 200)
        assertEquals("Open video in browser", result.getString("fallback"))
        compose.runOnIdle { assertTrue(view.settings.mediaPlaybackRequiresUserGesture) }
        capture("article-video")
    }

    @Test fun richContentRendersWithImagesMathAndContainedOverflow() {
        compose.runOnUiThread { compose.activity.setContent { MagpieTheme { ArticleReader(RichArticleSample.item, "") } } }
        val view = browser()
        var imageReady = false
        compose.waitUntil(10_000) {
            imageReady = inspect(view, "({loaded: document.querySelector('img').naturalWidth > 0})").getBoolean("loaded")
            imageReady
        }
        val result = inspect(view, """({
            heading: document.querySelector('h2').textContent,
            image: document.querySelector('img').naturalWidth,
            caption: !!document.querySelector('figcaption'), quote: !!document.querySelector('blockquote'),
            list: document.querySelectorAll('ol li').length,
            table: !!document.querySelector('table caption'),
            fractionHeight: document.querySelector('mfrac').getBoundingClientRect().height,
            numeratorHeight: document.querySelector('mfrac mn').getBoundingClientRect().height,
            codeOverflows: document.querySelector('pre').scrollWidth > document.querySelector('pre').clientWidth,
            pageFits: document.documentElement.scrollWidth <= window.innerWidth,
            imageFits: document.querySelector('img').getBoundingClientRect().width <= window.innerWidth,
            text: document.querySelector('main').textContent
        })""")
        assertEquals("A closer look", result.getString("heading"))
        assertTrue(imageReady)
        for (key in listOf("caption", "quote", "table", "codeOverflows", "pageFits", "imageFits")) assertTrue(key, result.getBoolean(key))
        assertEquals(3, result.getInt("list"))
        assertTrue("MathML must lay out the fraction", result.getDouble("fractionHeight") > result.getDouble("numeratorHeight"))
        assertTrue(result.getString("text").contains("The end of the field guide"))
        compose.runOnIdle { assertFalse(view.settings.allowFileAccess); assertFalse(view.settings.allowContentAccess) }
        capture("rich-article")
    }

    @Test fun searchFindsRichContentAndCanBeChangedOrCleared() {
        val query = mutableStateOf("")
        compose.runOnUiThread { compose.activity.setContent { MagpieTheme { ArticleReader(RichArticleSample.item, query.value) } } }
        val view = browser()
        compose.runOnIdle { query.value = "notice" }
        compose.waitUntil(10_000) { compose.onAllNodesWithText("1 of 3 matches").fetchSemanticsNodes().isNotEmpty() }
        compose.onNodeWithContentDescription("Next match").performClick()
        compose.waitUntil(10_000) { compose.onAllNodesWithText("2 of 3 matches").fetchSemanticsNodes().isNotEmpty() }
        compose.onNodeWithContentDescription("Previous match").performClick()
        compose.waitUntil(10_000) { compose.onAllNodesWithText("1 of 3 matches").fetchSemanticsNodes().isNotEmpty() }
        compose.runOnIdle { query.value = "not in this article" }
        compose.onNodeWithText("Nothing found").assertIsDisplayed()
        compose.onNodeWithContentDescription("Next match").assertIsNotEnabled()
        compose.runOnIdle { query.value = "" }
        compose.onNodeWithContentDescription("Next match").assertDoesNotExist()
        assertSame(view, browser())
    }

    @Test fun largeTextDarkThemeAndLongTablesStayWithinThePage() {
        val item = RichArticleSample.item.copy(html = RichArticleSample.item.html +
            "<table><tr>" + (1..12).joinToString("") { "<td>Column $it</td>" } + "</tr></table>")
        compose.runOnUiThread { compose.activity.setContent {
            val density = LocalDensity.current.density
            CompositionLocalProvider(LocalDensity provides Density(density, 2f)) {
                MagpieTheme(darkTheme = true) { ArticleReader(item, "", ArticleReadingPosition(item.id, item.contentVersion, 0, 2)) }
            }
        } }
        val view = browser()
        val result = inspect(view, """({
            font: getComputedStyle(document.body).fontSize,
            background: getComputedStyle(document.body).backgroundColor,
            pageFits: document.documentElement.scrollWidth <= window.innerWidth,
            tableOverflows: [...document.querySelectorAll('.table-scroll')].some(x => x.scrollWidth > x.clientWidth)
        })""")
        assertEquals("40px", result.getString("font"))
        assertEquals("rgb(17, 19, 24)", result.getString("background"))
        assertTrue(result.getBoolean("pageFits"))
        assertTrue(result.getBoolean("tableOverflows"))
        compose.waitUntil(5_000) { compose.runOnUiThread { view.readingMarker.rect != null } }
        capture("rich-article-large-dark")
    }

    @Test fun sampleArticleAndSearchSurviveActivityRecreation() {
        compose.onNodeWithText("Field notes").performClick()
        compose.onNodeWithTag("story-list").performScrollToNode(hasText(RichArticleSample.item.title))
        compose.onNodeWithText(RichArticleSample.item.title).performClick()
        browser()
        compose.onNodeWithContentDescription("Find in this page").performClick()
        compose.onNodeWithText("Find in this page").performTextInput("precisely")
        compose.waitUntil(10_000) { compose.onAllNodesWithText("1 of 1 matches").fetchSemanticsNodes().isNotEmpty() }
        compose.activityRule.scenario.recreate()
        browser()
        compose.onNodeWithText("Find in this page").assertTextContains("precisely")
        compose.waitUntil(10_000) { compose.onAllNodesWithText("1 of 1 matches").fetchSemanticsNodes().isNotEmpty() }
    }
    @Test fun readingMarkerAlignsAfterRichContentAndManualScrollingRequiresFollow() {
        val item = RichArticleSample.item
        val offset = item.text.indexOf("The end of the field guide")
        val position = mutableStateOf<ArticleReadingPosition?>(ArticleReadingPosition(item.id, item.contentVersion, offset, offset + 3))
        val followControl = ArticleFollowControl()
        compose.runOnUiThread { compose.activity.setContent { MagpieTheme {
            Column {
                Box(Modifier.weight(1f)) { ArticleReader(item, "", position.value, followControl) }
                MiniPlayer(PlayerState(item = item, connected = true), false, {}, {}, {}, followControl.actionFor(item.id))
            }
        } } }
        val view = browser()
        compose.waitUntil(10_000) { compose.runOnUiThread { view.readingMarker.rect != null && view.scrollY > 0 } }
        val geometry = inspect(view, """({top: document.querySelector('main > p:last-child').getBoundingClientRect().top + scrollY,
            width: innerWidth})""")
        compose.runOnIdle {
            val expected = geometry.getDouble("top") * view.width / geometry.getDouble("width")
            // Text glyph bounds start below the paragraph line box's top.
            assertEquals(expected, view.readingMarker.rect!!.top.toDouble(), 30.0)
        }
        capture("article-marker-scrolled")
        val beforeDrag = inspect(view, """({y: scrollY, height: innerHeight, total: document.documentElement.scrollHeight})""")
        val nativeBefore = compose.runOnUiThread { view.scrollY }
        // Pace real Android input for the WebView renderer. Compose's batched
        // synthetic gesture resets its scroll on this emulator even with a long
        // event duration; that does not represent a small, slow physical drag.
        val start = compose.runOnUiThread {
            val location = IntArray(2); view.getLocationOnScreen(location)
            androidx.compose.ui.geometry.Offset(location[0] + view.width / 2f, location[1] + view.height / 2f)
        }
        val instrumentation = androidx.test.platform.app.InstrumentationRegistry.getInstrumentation()
        val down = android.os.SystemClock.uptimeMillis()
        fun touch(action: Int, delta: Float) {
            val event = android.view.MotionEvent.obtain(down, android.os.SystemClock.uptimeMillis(), action,
                start.x, start.y + delta, 0)
            try { instrumentation.sendPointerSync(event) } finally { event.recycle() }
        }
        touch(android.view.MotionEvent.ACTION_DOWN, 0f)
        for (step in 1..10) { Thread.sleep(100); touch(android.view.MotionEvent.ACTION_MOVE, step * 8f) }
        touch(android.view.MotionEvent.ACTION_UP, 80f)
        compose.onNode(hasContentDescription("Follow reading position") and hasAnyAncestor(hasTestTag("mini-player"))).assertIsDisplayed()
        var lastY = compose.runOnUiThread { view.scrollY }
        var stableSince = android.os.SystemClock.elapsedRealtime()
        compose.waitUntil(5_000) {
            val y = compose.runOnUiThread { view.scrollY }
            if (y != lastY) { lastY = y; stableSince = android.os.SystemClock.elapsedRealtime() }
            android.os.SystemClock.elapsedRealtime() - stableSince >= 300
        }
        val afterDrag = inspect(view, """({y: scrollY, height: innerHeight, total: document.documentElement.scrollHeight, focus: document.activeElement.tagName})""")
        val attached = compose.runOnUiThread { view.isAttachedToWindow && view.ready }
        assertTrue("The manual drag must leave room to observe automatic scrolling: native=$nativeBefore, page=$beforeDrag, after=$lastY/$afterDrag, attached=$attached", lastY > 0)
        compose.runOnIdle { position.value = position.value!!.copy(startUtf16 = 0, endUtf16 = 2) }
        compose.waitUntil(5_000) { compose.runOnUiThread { view.readingMarker.rect!!.top < 600 } }
        val stoppedAt = compose.runOnUiThread { view.scrollY }
        Thread.sleep(350)
        assertEquals(stoppedAt, compose.runOnUiThread { view.scrollY })
        compose.onNodeWithContentDescription("Follow reading position").performClick()
        compose.waitUntil(5_000) { compose.runOnUiThread { view.scrollY == 0 } }
        compose.onNodeWithContentDescription("Follow reading position").assertDoesNotExist()
        capture("article-reading-marker")
        compose.runOnIdle { position.value = position.value!!.copy(itemId = "another-article") }
        compose.waitUntil(5_000) { compose.runOnUiThread { view.readingMarker.rect == null } }
    }

    @Test fun markerPreservesUnicodeAndRepeatedWordsWithoutRunningArticleScripts() {
        val text = "Café 🐦 first words. Repeat these words. Repeat these words. Last phrase."
        val item = RichArticleSample.item.copy(text = text, html = """
            <script>window.articleExecuted = true</script>
            <p onclick="window.articleExecuted = true">Café 🐦 <b>first</b> words.</p>
            <p>Repeat these words.</p><math><mi>x</mi></math>
            <p><a href="https://example.com">https://example.com</a> Repeat these words.</p>
            <p>Last phrase.</p><img src="data:image/png;base64,AAAA" onerror="window.articleExecuted = true">
        """)
        val offset = text.lastIndexOf("Repeat")
        val position = ArticleReadingPosition(item.id, item.contentVersion, offset, offset + 6)
        compose.runOnUiThread { compose.activity.setContent { MagpieTheme { ArticleReader(item, "", position) } } }
        val view = browser()
        compose.waitUntil(5_000) { compose.runOnUiThread { view.readingMarker.rect != null } }
        val result = inspect(view, """(() => {
            const r = document.createRange(); const node = document.querySelectorAll('main > p')[2].lastChild;
            r.setStart(node, 1); r.setEnd(node, 7);
            return {expected: r.getBoundingClientRect().top + scrollY,
                actual: magpieReadingMarker.rectForRange($offset, 6).top,
                executed: window.articleExecuted === true, scripts: document.querySelectorAll('script').length};
        })()""")
        assertEquals(result.getDouble("expected"), result.getDouble("actual"), 0.1)
        assertFalse(result.getBoolean("executed"))
        assertEquals(0, result.getInt("scripts"))
    }

}
