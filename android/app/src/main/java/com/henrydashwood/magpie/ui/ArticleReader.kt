package com.henrydashwood.magpie.ui

import android.content.ActivityNotFoundException
import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Canvas
import android.os.Bundle
import android.view.MotionEvent
import android.view.accessibility.AccessibilityNodeInfo
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.henrydashwood.magpie.playback.PlaybackStatus
import com.henrydashwood.magpie.playback.ArticleReadingPosition
import android.content.Intent
import android.graphics.Color as AndroidColor
import android.net.Uri
import android.webkit.CookieManager
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.compose.foundation.layout.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.KeyboardArrowDown
import androidx.compose.material.icons.rounded.KeyboardArrowUp
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import com.henrydashwood.magpie.data.LibraryItem
import com.henrydashwood.magpie.R
import java.io.ByteArrayInputStream

@Composable
fun ArticleReader(item: LibraryItem, query: String, followControl: ArticleFollowControl? = null) {
    val position by PlaybackStatus.readingPosition.collectAsStateWithLifecycle()
    ArticleReader(item, query, position, followControl)
}

@Composable
fun ArticleReader(item: LibraryItem, query: String, position: ArticleReadingPosition?, followControl: ArticleFollowControl? = null) {
    key(item.id) { ArticleReaderContent(item, query, position, followControl) }
}

@Composable
private fun ArticleReaderContent(item: LibraryItem, query: String, position: ArticleReadingPosition?, followControl: ArticleFollowControl?) {
    val colors = MaterialTheme.colorScheme
    val reading = position?.takeIf { it.itemId == item.id && it.contentVersion == item.contentVersion }
    var following by rememberSaveable(item.id) { mutableStateOf(true) }
    val fontSize = 20f * LocalDensity.current.fontScale
    val body = remember(item) { ArticleDocument.body(item) }
    val document = remember(item, body, fontSize, colors) {
        ArticleDocument.page(item, body, fontSize, colors.onSurface.css(), colors.surface.css(),
            colors.onSurfaceVariant.css(), colors.outlineVariant.css(), colors.primary.css(), colors.surface.luminance() < .5f)
    }
    var browser by remember { mutableStateOf<ArticleWebView?>(null) }
    val followOwner = remember { Any() }
    DisposableEffect(followControl, browser, reading?.itemId, following) {
        val view = browser
        if (reading != null && !following && view != null) {
            followControl?.offer(followOwner, item.id) { view.readingMarker.resume() }
        }
        onDispose { followControl?.clear(followOwner) }
    }
    var matchCount by remember { mutableIntStateOf(0) }
    var activeMatch by remember { mutableIntStateOf(0) }
    LaunchedEffect(query) { matchCount = 0; activeMatch = 0 }
    var scrollY by rememberSaveable(item.id) { mutableIntStateOf(0) }
    var error by remember { mutableStateOf<String?>(null) }
    val currentQuery by rememberUpdatedState(query)
    Column(Modifier.fillMaxSize()) {
        if (query.isNotBlank()) Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp)) {
            Text(if (matchCount == 0) "Nothing found" else "${activeMatch + 1} of $matchCount matches",
                Modifier.weight(1f).padding(vertical = 12.dp).semantics { liveRegion = LiveRegionMode.Polite })
            IconButton(enabled = matchCount > 0, onClick = { browser?.findNext(false) }) {
                Icon(Icons.Rounded.KeyboardArrowUp, "Previous match")
            }
            IconButton(enabled = matchCount > 0, onClick = { browser?.findNext(true) }) {
                Icon(Icons.Rounded.KeyboardArrowDown, "Next match")
            }
        }
        AndroidView(
            modifier = Modifier.fillMaxWidth().weight(1f).testTag("article-webview"),
            factory = { context ->
                ArticleWebView(context).also { view ->
                    browser = view
                    view.readingMarker.onFollowingChanged = { following = it }
                    view.openLink = { uri ->
                        try { context.startActivity(Intent(Intent.ACTION_VIEW, uri)) }
                        catch (_: ActivityNotFoundException) { error = "No app is available to open this link." }
                    }
                    view.setFindListener { active, count, done ->
                        if (done && currentQuery.isNotBlank()) { activeMatch = active; matchCount = count }
                    }
                    view.setOnScrollChangeListener { _, _, y, _, _ -> if (view.ready) scrollY = y }
                }
            },
            update = { view ->
                view.readingMarker.update(reading, colors.primary.toArgb(), following)
                view.display(document, query, scrollY, item.text)
            },
            onRelease = { view ->
                browser = null
                view.setOnScrollChangeListener(null)
                view.setFindListener(null)
                view.openLink = {}
                view.readingMarker.onFollowingChanged = {}
                view.release()
            },
        )
    }
    if (error != null) AlertDialog(onDismissRequest = { error = null }, title = { Text("Could not open") },
        text = { Text(error!!) }, confirmButton = { TextButton(onClick = { error = null }) { Text("Close") } })
}

private fun Color.css() = "#%06X".format(toArgb() and 0xFFFFFF)

/** Sanitized document viewer. Only app-owned geometry code runs; CSP blocks article scripts.
 * No JavaScript-to-native interface is exposed, and links never navigate to another document. */
@SuppressLint("SetJavaScriptEnabled")
class ArticleWebView(context: Context) : WebView(context) {
    val readingMarker = ArticleReadingMarker(this)
    var openLink: (Uri) -> Unit = {}
    var ready = false
        private set
    private var document: String? = null
    private var speechText = ""
    private var search = ""
    private var restoreY = 0
    private var generation = 0L
    private var released = false

    init {
        setBackgroundColor(AndroidColor.TRANSPARENT)
        settings.apply {
            javaScriptEnabled = true // Required for explicit, app-owned geometry evaluation; article CSP forbids scripts.
            domStorageEnabled = false
            allowFileAccess = false
            allowContentAccess = false
            mixedContentMode = WebSettings.MIXED_CONTENT_NEVER_ALLOW
            builtInZoomControls = true
            displayZoomControls = false
            textZoom = 100 // Font scaling is applied once, in the document's CSS.
            setGeolocationEnabled(false)
        }
        CookieManager.getInstance().setAcceptThirdPartyCookies(this, false)
        webViewClient = object : WebViewClient() {
            override fun onPageFinished(view: WebView, url: String?) {
                if (ready || released) return
                val loadedGeneration = generation
                postVisualStateCallback(loadedGeneration, object : VisualStateCallback() {
                    override fun onComplete(requestId: Long) {
                        if (released || requestId != generation) return
                        readingMarker.configure(speechText) {
                            if (released || requestId != generation) return@configure
                            ready = true
                            scrollTo(0, restoreY)
                            applySearch()
                        }
                    }
                })
            }

            override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean {
                val uri = request.url
                if (!request.isForMainFrame || !request.hasGesture()) return true
                if (uri.toString().startsWith("${ArticleDocument.LOCAL_BASE}#")) return false
                if (ArticleDocument.webUrl(uri.toString()) != null) openLink(uri)
                return true
            }

            override fun shouldInterceptRequest(view: WebView, request: WebResourceRequest): WebResourceResponse? {
                if (request.url.toString() == "https://magpie.invalid/assets/magpie.png") {
                    return sampleImage()
                }
                // CSP permits only images to reach the network; local files and content providers
                // remain blocked even if future markup accidentally references them.
                if (request.url.scheme == "https") return null
                return WebResourceResponse("text/plain", "UTF-8", ByteArrayInputStream(ByteArray(0)))
            }
        }
    }

    fun display(html: String, query: String, scroll: Int, text: String = "") {
        speechText = text
        val changedQuery = query != search
        search = query
        if (document != html) {
            document = html
            generation++
            readingMarker.reset()
            restoreY = scroll
            ready = false
            loadDataWithBaseURL(ArticleDocument.LOCAL_BASE, html, "text/html", "UTF-8", null)
        } else if (ready && changedQuery) applySearch()
    }

    private fun applySearch() {
        clearMatches()
        if (search.isNotBlank()) { readingMarker.detachFollowing(); findAllAsync(search) }
    }

    // openRawResource also opens file-backed drawable resources. This is a packaged PNG,
    // not an XML/vector drawable; reuse its bytes without duplicating the shared artwork.
    @SuppressLint("ResourceType")
    private fun sampleImage() = WebResourceResponse("image/png", null, resources.openRawResource(R.drawable.magpie_mark))

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        readingMarker.draw(canvas)
    }

    override fun dispatchTouchEvent(event: MotionEvent): Boolean {
        readingMarker.touch(event)
        return super.dispatchTouchEvent(event)
    }

    override fun performAccessibilityAction(action: Int, arguments: Bundle?): Boolean {
        if (action == AccessibilityNodeInfo.ACTION_SCROLL_FORWARD || action == AccessibilityNodeInfo.ACTION_SCROLL_BACKWARD) {
            readingMarker.detachFollowing()
        }
        return super.performAccessibilityAction(action, arguments)
    }

    fun maximumScrollY() = (computeVerticalScrollRange() - height).coerceAtLeast(0)

    fun release() {
        readingMarker.reset()
        released = true
        ready = false
        stopLoading()
        destroy()
    }
}
