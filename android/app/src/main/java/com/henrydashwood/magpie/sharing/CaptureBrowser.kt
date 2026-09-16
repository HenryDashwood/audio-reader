package com.henrydashwood.magpie.sharing

import android.annotation.SuppressLint
import android.graphics.Bitmap
import android.webkit.*
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.*
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import com.henrydashwood.magpie.data.validateLink
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject
import org.json.JSONTokener
import java.net.URI

fun captureWebUrl(url: String): Boolean = runCatching {
    URI(validateLink(url)).scheme.equals("https", true)
}.getOrDefault(false)

/** Website scripts run only here, with no native bridge, app tokens or file access. */
@OptIn(ExperimentalLayoutApi::class)
@SuppressLint("SetJavaScriptEnabled")
@Composable
fun CaptureBrowser(initialUrl: String, close: () -> Unit, captured: (SharedArticle) -> Unit) {
    val context = LocalContext.current
    var webView by remember { mutableStateOf<WebView?>(null) }
    var address by remember { mutableStateOf(initialUrl) }
    var loading by remember { mutableStateOf(true) }
    var extracting by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var script by remember { mutableStateOf<String?>(null) }
    var generation by remember { mutableIntStateOf(0) }
    var disposed by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) {
        script = withContext(Dispatchers.IO) { context.assets.open("capture/CapturePage.js").bufferedReader().use { it.readText() } }
    }
    DisposableEffect(Unit) {
        onDispose { disposed = true; generation++; webView?.apply { stopLoading(); destroy() }; webView = null }
    }
    BackHandler { if (webView?.canGoBack() == true) webView?.goBack() else close() }
    Scaffold { padding ->
        Column(Modifier.fillMaxSize().padding(padding)) {
            Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text("Capture page", style = MaterialTheme.typography.titleLarge, modifier = Modifier.semantics { heading() })
                Text(address, style = MaterialTheme.typography.bodySmall, maxLines = 2)
                FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    TextButton(onClick = close) { Text("Cancel") }
                    TextButton(onClick = { error = null; webView?.reload() }, enabled = !extracting) { Text("Reload") }
                    Button(enabled = !loading && !extracting && script != null && error == null && captureWebUrl(address), onClick = {
                        val view = webView ?: return@Button
                        val url = view.url ?: return@Button
                        val version = generation
                        extracting = true
                        val code = "(function(){\n" + script + "\nvar result; ExtensionPreprocessingJS.run({completionFunction:function(value){result=value;}}); return JSON.stringify(result);})()"
                        view.evaluateJavascript(code) { response ->
                            if (!disposed && version == generation && view.url == url) {
                                extracting = false
                                try { captured(decodeCapture(response, url)) }
                                catch (failure: Exception) { error = failure.message ?: "The page could not be captured. Save its link instead." }
                            }
                        }
                    }) { Text(if (extracting) "Capturing…" else "Preview article") }
                }
                error?.let { Text(it, color = MaterialTheme.colorScheme.error, modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite }) }
                if (error != null) TextButton(onClick = { captured(SharedArticle(address.takeIf(::captureWebUrl) ?: initialUrl)) }) { Text("Use link instead") }
            }
            if (loading || extracting) LinearProgressIndicator(Modifier.fillMaxWidth())
            AndroidView(modifier = Modifier.weight(1f).fillMaxWidth(), factory = { ctx ->
                WebView(ctx).apply {
                    webView = this
                    settings.javaScriptEnabled = true
                    settings.domStorageEnabled = true
                    settings.textZoom = (ctx.resources.configuration.fontScale * 100).toInt()
                    settings.useWideViewPort = true
                    settings.loadWithOverviewMode = true
                    settings.builtInZoomControls = true
                    settings.displayZoomControls = false
                    settings.allowFileAccess = false
                    settings.allowContentAccess = false
                    settings.mixedContentMode = WebSettings.MIXED_CONTENT_NEVER_ALLOW
                    settings.setSupportMultipleWindows(false)
                    settings.javaScriptCanOpenWindowsAutomatically = false
                    settings.safeBrowsingEnabled = true
                    CookieManager.getInstance().setAcceptThirdPartyCookies(this, false)
                    webChromeClient = object : WebChromeClient() {
                        override fun onPermissionRequest(request: PermissionRequest) { request.deny() }
                    }
                    setDownloadListener { _, _, _, _, _ -> error = "Downloads cannot be captured. Open an article page instead." }
                    webViewClient = object : WebViewClient() {
                        override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean {
                            val allowed = captureWebUrl(request.url.toString())
                            if (!allowed && request.isForMainFrame) error = "Only secure web pages can be opened here."
                            return !allowed
                        }
                        override fun shouldInterceptRequest(view: WebView, request: WebResourceRequest): WebResourceResponse? {
                            if (request.url.scheme in listOf("https", "data", "blob")) return null
                            return WebResourceResponse("text/plain", "UTF-8", java.io.ByteArrayInputStream(byteArrayOf()))
                        }
                        override fun onPageStarted(view: WebView, url: String, favicon: Bitmap?) {
                            generation++; extracting = false; loading = true; error = null; address = url
                        }
                        override fun onPageFinished(view: WebView, url: String) { if (view.url == url) { loading = false; address = url } }
                        override fun onReceivedError(view: WebView, request: WebResourceRequest, failure: WebResourceError) {
                            if (request.isForMainFrame) { loading = false; error = "This page could not load. Try again or save its link." }
                        }
                        override fun onReceivedHttpError(view: WebView, request: WebResourceRequest, response: WebResourceResponse) {
                            if (request.isForMainFrame) { loading = false; error = "The website could not open this page. Try again or save its link." }
                        }
                        override fun onReceivedSslError(view: WebView, handler: SslErrorHandler, failure: android.net.http.SslError) {
                            handler.cancel(); loading = false; error = "This page’s secure connection could not be verified."
                        }
                    }
                    if (captureWebUrl(initialUrl)) loadUrl(initialUrl) else { loading = false; error = "Only secure web pages can be opened here." }
                }
            })
        }
    }
}

fun decodeCapture(response: String, expectedUrl: String): SharedArticle {
    require(response.length <= SharedArticles.MAX_BYTES * 2) { "This page is too large to capture. Save its link instead." }
    val json = JSONObject(JSONTokener(response).nextValue() as String)
    val url = validateLink(json.getString("url"))
    require(url == expectedUrl && captureWebUrl(url)) { "The page changed while capturing. Try again." }
    val html = json.optString("html").takeIf { it.isNotBlank() }
    val article = SharedArticles.parse(url, json.optString("title"), html)
    return article.copy(contentFormat = if (html != null && json.optString("contentFormat") == "article") "article" else "page")
}
