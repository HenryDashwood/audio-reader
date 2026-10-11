package com.henrydashwood.magpie.sharing

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Bitmap
import android.os.Message
import android.widget.FrameLayout
import android.view.View
import android.view.ViewGroup
import android.webkit.*
import androidx.activity.compose.BackHandler
import androidx.annotation.VisibleForTesting
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.*
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import com.henrydashwood.magpie.data.validateLink
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import org.json.JSONObject
import org.json.JSONTokener
import java.net.URI
import kotlin.coroutines.resume
import kotlinx.coroutines.suspendCancellableCoroutine

fun captureWebUrl(url: String): Boolean = runCatching {
    URI(validateLink(url)).scheme.equals("https", true)
}.getOrDefault(false)

/** Test seam: serves fixture documents instead of the network. Null in the app. */
@VisibleForTesting
object CaptureFixtures {
    @Volatile var respond: ((String) -> WebResourceResponse?)? = null
}

private interface CaptureEvents {
    fun started(url: String)
    fun finished(view: WebView, url: String)
    fun failed(message: String, url: String?)
}

private suspend fun captureScript(context: Context) =
    withContext(Dispatchers.IO) { context.assets.open("capture/CapturePage.js").bufferedReader().use { it.readText() } }

/** Runs Safari's share-extension script in the loaded page; [done] receives its raw JSON string. */
private fun extract(view: WebView, script: String, done: (String) -> Unit) {
    val code = "(function(){\n" + script + "\nvar result; ExtensionPreprocessingJS.run({completionFunction:function(value){result=value;}}); return JSON.stringify(result);})()"
    view.evaluateJavascript(code, done)
}

/**
 * Website scripts run only in these views, with no native bridge, app tokens or file access.
 * Website cookies are shared by every capture view, so a sign-in made in Website sign-ins
 * also serves shares from other browsers.
 */
@SuppressLint("SetJavaScriptEnabled")
private fun captureWebView(
    context: Context, textZoom: Int, events: CaptureEvents, policy: () -> String?,
    openWindow: ((WebView, Boolean, Message) -> Boolean)? = null,
    closeWindow: ((WebView) -> Unit)? = null,
) = WebView(context).apply {
    // Compose supplies the viewport bounds, but WebView also consults native
    // layout parameters for CSS viewport units. WRAP_CONTENT makes 100dvh zero
    // and can place a website's bottom-sheet sign-in form below the screen.
    layoutParams = ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT)
    settings.javaScriptEnabled = true
    settings.domStorageEnabled = true
    settings.textZoom = textZoom
    settings.useWideViewPort = true
    settings.loadWithOverviewMode = true
    settings.builtInZoomControls = true
    settings.displayZoomControls = false
    settings.allowFileAccess = false
    settings.allowContentAccess = false
    settings.mixedContentMode = WebSettings.MIXED_CONTENT_NEVER_ALLOW
    // Otherwise window.open replaces its opener, breaking the return handshake.
    // Hidden capture views reject windows; visible capture owns at most one.
    settings.setSupportMultipleWindows(true)
    settings.javaScriptCanOpenWindowsAutomatically = false
    settings.mediaPlaybackRequiresUserGesture = true
    settings.safeBrowsingEnabled = true
    CookieManager.getInstance().setAcceptCookie(true)
    CookieManager.getInstance().setAcceptThirdPartyCookies(this, false)
    webChromeClient = object : WebChromeClient() {
        override fun onPermissionRequest(request: PermissionRequest) { request.deny() }
        override fun onCreateWindow(view: WebView, isDialog: Boolean, isUserGesture: Boolean, resultMsg: Message): Boolean =
            openWindow?.invoke(view, isUserGesture, resultMsg) ?: false
        override fun onCloseWindow(window: WebView) { closeWindow?.invoke(window) }
    }
    setDownloadListener { _, _, _, _, _ -> events.failed("Downloads cannot be captured. Open an article page instead.", null) }
    webViewClient = object : WebViewClient() {
        private var navigation = 0
        private var currentPage: String? = null
        // WebView can report an HTTP error before onPageStarted. Bind status to
        // its request URL instead of clearing it in that later callback.
        private val responses = mutableMapOf<String, Pair<Int, Boolean>>()
        private val repaired = mutableSetOf<String>()
        override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean {
            val url = request.url.toString()
            val allowed = captureWebUrl(url)
            if (!allowed && request.isForMainFrame) events.failed("Only secure web pages can be opened here.", null)
            return !allowed
        }
        override fun shouldInterceptRequest(view: WebView, request: WebResourceRequest): WebResourceResponse? {
            CaptureFixtures.respond?.let { return it(request.url.toString()) }
            if (request.url.scheme in listOf("https", "data", "blob")) return null
            return WebResourceResponse("text/plain", "UTF-8", java.io.ByteArrayInputStream(byteArrayOf()))
        }
        override fun onPageStarted(view: WebView, url: String, favicon: Bitmap?) {
            currentPage = url
            navigation++; events.started(url)
        }
        override fun doUpdateVisitedHistory(view: WebView, url: String, isReload: Boolean) {
            // Client-side routers can change pages without onPageStarted or
            // onPageFinished. Keep the address and capture generation current.
            if (view.url == url && currentPage != url && view.progress == 100) {
                currentPage = url
                navigation++; events.started(url); events.finished(view, url)
            }
        }
        override fun onPageFinished(view: WebView, url: String) {
            if (view.url != url) return
            val response = responses.remove(url)
            val httpStatus = response?.first
            val retryableRequest = response?.second == true
            val code = policy()
            if (httpStatus == 400 && retryableRequest && code != null && url !in repaired && repaired.size < 4) {
                val version = navigation
                view.evaluateJavascript(code + "\nJSON.stringify(MagpieCapturePolicy.navigationRetry(document, 400));") { response ->
                    if (version != navigation || view.url != url) return@evaluateJavascript
                    val target = runCatching { JSONTokener(JSONTokener(response).nextValue() as String).nextValue() as? String }.getOrNull()
                    if (target != null && captureWebUrl(target) && URI(target).authority == URI(url).authority) {
                        repaired += url; view.loadUrl(target)
                    } else events.failed("The website could not open this page. Try again or save its link.", url)
                }
            } else if (httpStatus != null && httpStatus >= 400) {
                events.failed("The website could not open this page. Try again or save its link.", url)
            } else events.finished(view, url)
        }
        override fun onReceivedError(view: WebView, request: WebResourceRequest, failure: WebResourceError) {
            if (request.isForMainFrame) events.failed("This page could not load. Try again or save its link.", request.url.toString())
        }
        override fun onReceivedHttpError(view: WebView, request: WebResourceRequest, response: WebResourceResponse) {
            if (request.isForMainFrame) {
                if (responses.size >= 16) responses.clear()
                responses[request.url.toString()] = response.statusCode to (request.method == "GET")
                if (response.statusCode != 400) events.failed("The website could not open this page. Try again or save its link.", request.url.toString())
            }
        }
        override fun onReceivedSslError(view: WebView, handler: SslErrorHandler, failure: android.net.http.SslError) {
            handler.cancel(); events.failed("This page’s secure connection could not be verified.", failure.url)
        }
    }
}

/**
 * A visible browser. Capturing (Saved's "Capture page") previews the extracted article;
 * with [signIn] it only lets the user sign in to a website for later captures.
 */
@OptIn(ExperimentalLayoutApi::class)
@Composable
fun CaptureBrowser(initialUrl: String, close: () -> Unit, captured: (SharedArticle) -> Unit = {}, signIn: Boolean = false) {
    val context = LocalContext.current
    var webView by remember { mutableStateOf<WebView?>(null) }
    var popup by remember { mutableStateOf<WebView?>(null) }
    var container by remember { mutableStateOf<FrameLayout?>(null) }
    var address by remember { mutableStateOf(initialUrl) }
    var loading by remember { mutableStateOf(true) }
    var extracting by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var script by remember { mutableStateOf<String?>(null) }
    var generation by remember { mutableIntStateOf(0) }
    var disposed by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) { script = captureScript(context) }
    DisposableEffect(Unit) {
        onDispose {
            disposed = true; generation++
            container?.removeAllViews(); container = null
            popup?.apply { stopLoading(); destroy() }; popup = null
            webView?.apply { stopLoading(); destroy() }; webView = null
            CookieManager.getInstance().flush()
        }
    }
    fun dismissWindow() {
        val child = popup ?: return
        generation++; extracting = false
        container?.removeView(child); child.stopLoading(); child.destroy(); popup = null
        webView?.let {
            it.visibility = View.VISIBLE
            it.importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_AUTO
            address = it.url ?: initialUrl; loading = it.progress < 100
        }
        error = null
    }
    fun events(forPopup: Boolean) = object : CaptureEvents {
        private fun active() = !disposed && forPopup == (popup != null)
        override fun started(url: String) {
            if (active()) { generation++; extracting = false; loading = true; error = null; address = url }
        }
        override fun finished(view: WebView, url: String) { if (active()) { loading = false; address = url } }
        override fun failed(message: String, url: String?) { if (active()) { loading = false; error = message } }
    }
    BackHandler {
        val child = popup
        if (child != null) { if (child.canGoBack()) child.goBack() else dismissWindow() }
        else if (webView?.canGoBack() == true) webView?.goBack() else close()
    }
    Scaffold { padding ->
        Column(Modifier.fillMaxSize().padding(padding)) {
            Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(if (popup != null) "Website window" else if (signIn) "Website sign-in" else "Capture page", style = MaterialTheme.typography.titleLarge, modifier = Modifier.semantics { heading() })
                Text(address, style = MaterialTheme.typography.bodySmall, maxLines = 2)
                FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    if (!signIn) TextButton(onClick = close) { Text("Cancel") }
                    TextButton(onClick = { error = null; (popup ?: webView)?.reload() }, enabled = !extracting) { Text("Reload") }
                    if (popup != null) TextButton(onClick = ::dismissWindow) { Text("Close window") }
                    if (signIn) Button(onClick = close) { Text("Done") }
                    else Button(enabled = popup == null && !loading && !extracting && script != null && error == null && captureWebUrl(address), onClick = {
                        val view = webView ?: return@Button
                        val url = view.url ?: return@Button
                        val version = generation
                        extracting = true
                        extract(view, script!!) { response ->
                            if (!disposed && version == generation && view.url == url) {
                                extracting = false
                                try {
                                    val article = decodeCapture(response, url)
                                    require(article.captureIssue == null) { article.captureIssue!!.message }
                                    require(article.html != null) {
                                        "Magpie could not capture the article text. Make sure the full article has loaded and you are signed in, then try again."
                                    }
                                    captured(article)
                                }
                                catch (failure: Exception) { error = failure.message ?: "The page could not be captured. Save its link instead." }
                            }
                        }
                    }) { Text(if (extracting) "Capturing…" else "Preview article") }
                }
                if (popup != null) Text("Some sign-in providers do not support this browser. If sign-in stalls, close this window and try the website’s email sign-in option.", style = MaterialTheme.typography.bodySmall)
                error?.let { Text(it, color = MaterialTheme.colorScheme.error, modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite }) }
                if (error != null && !signIn && popup == null) TextButton(onClick = { captured(SharedArticle(address.takeIf(::captureWebUrl) ?: initialUrl)) }) { Text("Use link instead") }
            }
            if (loading || extracting) LinearProgressIndicator(Modifier.fillMaxWidth())
            if (script != null) AndroidView(modifier = Modifier.weight(1f).fillMaxWidth(), factory = { ctx ->
                FrameLayout(ctx).also { holder ->
                    container = holder
                    val zoom = (ctx.resources.configuration.fontScale * 100).toInt()
                    val root = captureWebView(ctx, zoom, events(false), policy = { script }, openWindow = { parent, userGesture, message ->
                        if (!userGesture || popup != null || disposed) false
                        else {
                            val transport = message.obj as? WebView.WebViewTransport
                            if (transport == null) false
                            else {
                                val child = captureWebView(ctx, zoom, events(true), policy = { script },
                                    closeWindow = { window -> if (window === popup) dismissWindow() })
                                generation++; extracting = false; loading = true; error = null
                                address = "Opening website window…"; popup = child
                                parent.importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS
                                // Keep its measured viewport and JS context, but remove the
                                // covered document from touch and accessibility traversal.
                                parent.visibility = View.INVISIBLE
                                holder.addView(child); child.requestFocus()
                                transport.webView = child; message.sendToTarget()
                                true
                            }
                        }
                    })
                    webView = root; holder.addView(root)
                    if (captureWebUrl(initialUrl)) root.loadUrl(initialUrl) else { loading = false; error = "Only secure web pages can be opened here." }
                }
            })
        }
    }
}

/**
 * Loads [url] out of sight and runs the same extraction as Safari's share extension, so one
 * Save captures the rendered page. A detected membership gate requests website sign-in;
 * other uncertain extractions return null so the share can retain its link.
 */
@Composable
fun HiddenPageCapture(url: String, done: (SharedArticle?) -> Unit) {
    val context = LocalContext.current
    val finish by rememberUpdatedState(done)
    var script by remember { mutableStateOf<String?>(null) }
    var webView by remember { mutableStateOf<WebView?>(null) }
    // The page URL after it finishes loading; a later navigation restarts the settle wait.
    var loaded by remember { mutableStateOf<Pair<Int, String>?>(null) }
    var generation by remember { mutableIntStateOf(0) }
    var reported by remember { mutableStateOf(false) }
    fun report(article: SharedArticle?) { if (!reported) { reported = true; finish(article) } }
    LaunchedEffect(Unit) { script = runCatching { captureScript(context) }.getOrNull() ?: run { report(null); null } }
    DisposableEffect(Unit) { onDispose { generation++; webView?.apply { stopLoading(); destroy() }; webView = null } }
    LaunchedEffect(loaded, script) {
        val (version, page) = loaded ?: return@LaunchedEffect
        val code = script ?: return@LaunchedEffect
        // Require two matching captures across separate settle intervals. A late
        // gate or changing body cannot be accepted from a single early snapshot.
        var previous: SharedArticle? = null
        repeat(3) {
            delay(SETTLE_MILLIS)
            val view = webView ?: return@LaunchedEffect
            if (version != generation || view.url != page) return@LaunchedEffect
            val response = suspendCancellableCoroutine<String> { continuation ->
                extract(view, code) { if (continuation.isActive) continuation.resume(it) }
            }
            if (version != generation || view.url != page) return@LaunchedEffect
            val article = runCatching { decodeCapture(response, page) }.getOrNull()
            if (article?.requiresWebsiteSignIn == true || article != null && article == previous) {
                report(article); return@LaunchedEffect
            }
            previous = article
        }
        report(SharedArticle(page, captureIssue = CaptureIssue.INCOMPLETE))
    }
    // Laid out at phone size but transparent and hidden from accessibility services.
    Box(Modifier.size(1.dp).clearAndSetSemantics { }) {
        if (script != null) AndroidView(modifier = Modifier.requiredSize(390.dp, 844.dp).alpha(0f), factory = { ctx ->
            captureWebView(ctx, 100, object : CaptureEvents {
                override fun started(url: String) { generation++; loaded = null }
                override fun finished(view: WebView, url: String) { loaded = generation to url }
                override fun failed(message: String, url: String?) { report(null) }
            }, policy = { script }).also { view ->
                view.importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS
                view.isFocusable = false
                webView = view
                if (captureWebUrl(url)) view.loadUrl(url) else report(null)
            }
        })
    }
}

private const val SETTLE_MILLIS = 1_000L

fun decodeCapture(response: String, expectedUrl: String): SharedArticle {
    require(response.length <= SharedArticles.MAX_BYTES * 2) { "This page is too large to capture. Save its link instead." }
    val json = JSONObject(JSONTokener(response).nextValue() as String)
    val url = validateLink(json.getString("url"))
    require(url == expectedUrl && captureWebUrl(url)) { "The page changed while capturing. Try again." }
    val html = json.optString("html").takeIf { it.isNotBlank() }
    if (html == null) return SharedArticle(url, title = json.optString("title"),
        captureIssue = CaptureIssue.fromReason(json.optString("captureFailure")))
    val article = SharedArticles.parse(url, json.optString("title"), html)
    return article.copy(contentFormat = if (json.optString("contentFormat") == "article") "article" else "page")
}
