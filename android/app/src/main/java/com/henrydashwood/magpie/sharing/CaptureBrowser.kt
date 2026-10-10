package com.henrydashwood.magpie.sharing

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Bitmap
import android.view.View
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

fun captureWebUrl(url: String): Boolean = runCatching {
    URI(validateLink(url)).scheme.equals("https", true)
}.getOrDefault(false)

/** Test seam: serves fixture documents instead of the network. Null in the app. */
@VisibleForTesting
object CaptureFixtures { @Volatile var respond: ((String) -> WebResourceResponse?)? = null }

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
private fun captureWebView(context: Context, textZoom: Int, events: CaptureEvents) = WebView(context).apply {
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
    settings.setSupportMultipleWindows(false)
    settings.javaScriptCanOpenWindowsAutomatically = false
    settings.mediaPlaybackRequiresUserGesture = true
    settings.safeBrowsingEnabled = true
    CookieManager.getInstance().setAcceptCookie(true)
    CookieManager.getInstance().setAcceptThirdPartyCookies(this, false)
    webChromeClient = object : WebChromeClient() {
        override fun onPermissionRequest(request: PermissionRequest) { request.deny() }
    }
    setDownloadListener { _, _, _, _, _ -> events.failed("Downloads cannot be captured. Open an article page instead.", null) }
    webViewClient = object : WebViewClient() {
        override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean {
            val allowed = captureWebUrl(request.url.toString())
            if (!allowed && request.isForMainFrame) events.failed("Only secure web pages can be opened here.", null)
            return !allowed
        }
        override fun shouldInterceptRequest(view: WebView, request: WebResourceRequest): WebResourceResponse? {
            CaptureFixtures.respond?.let { return it(request.url.toString()) }
            if (request.url.scheme in listOf("https", "data", "blob")) return null
            return WebResourceResponse("text/plain", "UTF-8", java.io.ByteArrayInputStream(byteArrayOf()))
        }
        override fun onPageStarted(view: WebView, url: String, favicon: Bitmap?) { events.started(url) }
        override fun onPageFinished(view: WebView, url: String) { if (view.url == url) events.finished(view, url) }
        override fun onReceivedError(view: WebView, request: WebResourceRequest, failure: WebResourceError) {
            if (request.isForMainFrame) events.failed("This page could not load. Try again or save its link.", request.url.toString())
        }
        override fun onReceivedHttpError(view: WebView, request: WebResourceRequest, response: WebResourceResponse) {
            if (request.isForMainFrame) events.failed("The website could not open this page. Try again or save its link.", request.url.toString())
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
    var address by remember { mutableStateOf(initialUrl) }
    var loading by remember { mutableStateOf(true) }
    var extracting by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var script by remember { mutableStateOf<String?>(null) }
    var generation by remember { mutableIntStateOf(0) }
    var disposed by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) { if (!signIn) script = captureScript(context) }
    DisposableEffect(Unit) {
        onDispose {
            disposed = true; generation++; webView?.apply { stopLoading(); destroy() }; webView = null
            CookieManager.getInstance().flush()
        }
    }
    BackHandler { if (webView?.canGoBack() == true) webView?.goBack() else close() }
    Scaffold { padding ->
        Column(Modifier.fillMaxSize().padding(padding)) {
            Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(if (signIn) "Website sign-in" else "Capture page", style = MaterialTheme.typography.titleLarge, modifier = Modifier.semantics { heading() })
                Text(address, style = MaterialTheme.typography.bodySmall, maxLines = 2)
                FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    if (!signIn) TextButton(onClick = close) { Text("Cancel") }
                    TextButton(onClick = { error = null; webView?.reload() }, enabled = !extracting) { Text("Reload") }
                    if (signIn) Button(onClick = close) { Text("Done") }
                    else Button(enabled = !loading && !extracting && script != null && error == null && captureWebUrl(address), onClick = {
                        val view = webView ?: return@Button
                        val url = view.url ?: return@Button
                        val version = generation
                        extracting = true
                        extract(view, script!!) { response ->
                            if (!disposed && version == generation && view.url == url) {
                                extracting = false
                                try { captured(decodeCapture(response, url)) }
                                catch (failure: Exception) { error = failure.message ?: "The page could not be captured. Save its link instead." }
                            }
                        }
                    }) { Text(if (extracting) "Capturing…" else "Preview article") }
                }
                error?.let { Text(it, color = MaterialTheme.colorScheme.error, modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite }) }
                if (error != null && !signIn) TextButton(onClick = { captured(SharedArticle(address.takeIf(::captureWebUrl) ?: initialUrl)) }) { Text("Use link instead") }
            }
            if (loading || extracting) LinearProgressIndicator(Modifier.fillMaxWidth())
            AndroidView(modifier = Modifier.weight(1f).fillMaxWidth(), factory = { ctx ->
                captureWebView(ctx, (ctx.resources.configuration.fontScale * 100).toInt(), object : CaptureEvents {
                    override fun started(url: String) { generation++; extracting = false; loading = true; error = null; address = url }
                    override fun finished(view: WebView, url: String) { loading = false; address = url }
                    override fun failed(message: String, url: String?) { loading = false; error = message }
                }).also { view ->
                    webView = view
                    if (captureWebUrl(initialUrl)) view.loadUrl(initialUrl) else { loading = false; error = "Only secure web pages can be opened here." }
                }
            })
        }
    }
}

/**
 * Loads [url] out of sight and runs the same extraction as Safari's share extension, so one
 * Save captures the rendered page. Reports null when the page offers no confident article;
 * the share then saves its link for the server to fetch, as before.
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
        // Let client-rendered pages and late paywall checks settle before reading the DOM.
        delay(SETTLE_MILLIS)
        val view = webView ?: return@LaunchedEffect
        if (version != generation || view.url != page) return@LaunchedEffect
        extract(view, code) { response ->
            if (version != generation || view.url != page) return@extract
            val article = runCatching { decodeCapture(response, page) }.getOrNull()
            report(article?.takeIf { it.html != null })
        }
    }
    // Laid out at phone size but transparent and hidden from accessibility services.
    Box(Modifier.size(1.dp).clearAndSetSemantics { }) {
        AndroidView(modifier = Modifier.requiredSize(390.dp, 844.dp).alpha(0f), factory = { ctx ->
            captureWebView(ctx, 100, object : CaptureEvents {
                override fun started(url: String) { generation++; loaded = null }
                override fun finished(view: WebView, url: String) { loaded = generation to url }
                override fun failed(message: String, url: String?) { report(null) }
            }).also { view ->
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
    val article = SharedArticles.parse(url, json.optString("title"), html)
    return article.copy(contentFormat = if (html != null && json.optString("contentFormat") == "article") "article" else "page")
}
