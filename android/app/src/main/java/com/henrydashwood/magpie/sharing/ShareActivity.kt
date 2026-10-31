package com.henrydashwood.magpie.sharing

import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.lifecycle.ViewModelProvider
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.Article
import androidx.compose.material.icons.outlined.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import com.henrydashwood.magpie.R
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.*
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.henrydashwood.magpie.MainActivity
import com.henrydashwood.magpie.ui.MagpieTheme

class ShareActivity : ComponentActivity() {
    private val model by lazy { ViewModelProvider(this)[ShareModel::class.java] }
    private var pdfIntent by mutableStateOf<Intent?>(null)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        pdfIntent = intent.takeIf { it.type == "application/pdf" }
        if (pdfIntent == null) model.receive(intent, savedInstanceState?.getBoolean("saved") == true, capture = capturing(intent))
        setContent { MagpieTheme {
            val incoming = pdfIntent
            if (incoming != null) {
                val uri = androidx.core.content.IntentCompat.getParcelableExtra(incoming, Intent.EXTRA_STREAM, android.net.Uri::class.java)
                    ?: incoming.clipData?.takeIf { it.itemCount == 1 }?.getItemAt(0)?.uri
                key(incoming) {
                    com.henrydashwood.magpie.ui.PDFImportDialog(initialUri = uri, onClose = ::finish)
                }
            } else ShareScreen(model, ::finish, ::openMagpie)
        } }
    }
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent); setIntent(intent)
        pdfIntent = intent.takeIf { it.type == "application/pdf" }
        if (pdfIntent == null) model.receive(intent, fresh = true, capture = capturing(intent))
    }
    override fun onSaveInstanceState(outState: Bundle) {
        // Never put page HTML in the activity bundle. After process death, an unconfirmed
        // browser preview returns to the original share for fresh review.
        outState.putBoolean("saved", model.state.value.saved)
        super.onSaveInstanceState(outState)
    }
    private fun capturing(intent: Intent) = intent.component?.className == CAPTURE_PAGE
    companion object { const val CAPTURE_PAGE = "com.henrydashwood.magpie.sharing.CapturePage" }
    private fun openMagpie() {
        startActivity(Intent(this, MainActivity::class.java).putExtra("open_saved", true)
            .putExtra("open_signin", !model.library.value.live)
            .addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP))
        if (model.state.value.saved) finish()
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ShareScreen(model: ShareModel, close: () -> Unit, openMagpie: () -> Unit) {
    val state by model.state.collectAsStateWithLifecycle()
    val library by model.library.collectAsStateWithLifecycle()
    if (state.browser && state.article != null) {
        CaptureBrowser(state.article!!.url, model::closeBrowser, model::captured)
        return
    }
    BackHandler(enabled = state.busy) { /* Keep the durable-write acknowledgement visible. */ }
    val reading = state.article?.url?.takeIf { state.preparing }
    if (reading != null) key(reading) { HiddenPageCapture(reading, model::prepared) }
    val busy by rememberUpdatedState(state.busy)
    val sheet = rememberModalBottomSheetState(skipPartiallyExpanded = true,
        confirmValueChange = { it != SheetValue.Hidden || !busy })
    val colours = sheetColours()
    ModalBottomSheet(onDismissRequest = { if (!state.busy) close() }, sheetState = sheet, containerColor = colours.sheet) {
        SheetContent(state, library.live, library.owner != null, model, close, openMagpie, colours)
    }
}

@Composable
private fun SheetContent(state: ShareState, live: Boolean, loaded: Boolean, model: ShareModel,
    close: () -> Unit, openMagpie: () -> Unit, colours: SheetColours) {
    val article = state.article
    val blocked = article == null && state.error != null
    Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(start = 24.dp, end = 24.dp, bottom = 24.dp),
        verticalArrangement = Arrangement.spacedBy(20.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
            Box(Modifier.size(44.dp).clip(RoundedCornerShape(12.dp)).background(Color(0xFF111318)).padding(5.dp)) {
                Image(painterResource(R.drawable.magpie_mark), contentDescription = null)
            }
            Text(when { state.saved -> "Saved to Magpie"; blocked -> "Can't save this"; else -> "Save to Magpie" },
                style = MaterialTheme.typography.headlineSmall,
                modifier = Modifier.semantics { heading(); liveRegion = LiveRegionMode.Polite })
        }
        if (article != null) ItemCard(article, preview = !state.saved && article.contentFormat != "pdf", colours)
        when {
            state.saved -> Status(Icons.Outlined.CheckCircle, "Saved on this device. Open Magpie to prepare it for reading and listening.")
            blocked -> Notice(Icons.Outlined.ErrorOutline, state.error!!, colours.errorContainer, colours.onErrorContainer)
            article == null -> LinearProgressIndicator(Modifier.fillMaxWidth())
            state.accountChanged -> Notice(Icons.Outlined.Info, state.error ?: "Your account changed. Review this again before saving.",
                colours.warningContainer, colours.onWarningContainer)
            !live -> Status(Icons.Outlined.AccountCircle, "Sign in to Magpie before saving. Return here afterward to review and save this.")
            !loaded -> Status(Icons.Outlined.AccountCircle, "Connect to load your Magpie account before saving. Open Magpie to retry.")
            state.error != null -> Notice(Icons.Outlined.ErrorOutline, state.error, colours.errorContainer, colours.onErrorContainer)
            article.contentFormat == "pdf" -> Status(Icons.Outlined.Lock,
                "Magpie turns this PDF into text you can listen to. Datalab prepares it privately for your account.")
            state.preparing -> Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                LinearProgressIndicator(Modifier.fillMaxWidth())
                Text(if (state.saveRequested) "Reading the page before saving…" else "Reading the page…",
                    style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite })
            }
            article.captureIssue != null -> Notice(Icons.Outlined.Lock, article.captureIssue.message,
                colours.warningContainer, colours.onWarningContainer)
            article.html != null -> Status(Icons.Outlined.CheckCircle, "Article text found. Saving again updates your copy.")
            else -> Status(Icons.Outlined.Link, "Only the link was captured. Magpie will try to fetch the article, but pages that require a website sign-in may not be readable.")
        }
        Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
            val enabled = !state.busy
            when {
                state.saved -> {
                    PrimaryButton("Open Magpie", onClick = openMagpie)
                    SecondaryButton("Done", onClick = close)
                }
                blocked -> FilledTonalButton(onClick = close, Modifier.fillMaxWidth().heightIn(min = 56.dp)) { Text("Close", style = buttonText) }
                article == null -> SecondaryButton("Cancel", onClick = close)
                state.accountChanged -> {
                    PrimaryButton("Review again", onClick = model::reviewAccount)
                    SecondaryButton("Cancel", onClick = close)
                }
                !live || !loaded -> {
                    PrimaryButton("Open Magpie", onClick = openMagpie, enabled = enabled)
                    SecondaryButton("Cancel", onClick = close, enabled = enabled)
                }
                else -> {
                    when {
                        article.contentFormat == "pdf" -> PrimaryButton("Save", onClick = model::save, enabled = enabled)
                        article.captureIssue != null -> {
                            if (captureWebUrl(article.url)) PrimaryButton(
                                if (article.requiresWebsiteSignIn) "Sign in to website" else "Open page to capture",
                                onClick = model::openBrowser, enabled = enabled)
                            OutlinedButton(onClick = model::saveLink, Modifier.fillMaxWidth().heightIn(min = 52.dp).padding(top = 4.dp),
                                enabled = enabled) { Text("Save link only", style = buttonText) }
                        }
                        article.html == null && !state.preparing -> PrimaryButton("Save", onClick = model::saveLink, enabled = enabled)
                        else -> PrimaryButton("Save", onClick = model::save, enabled = enabled && !state.saveRequested)
                    }
                    SecondaryButton("Cancel", onClick = close, enabled = enabled)
                    // A site may hand over only a preview; capturing the page in Magpie stays one tap away.
                    if (article.contentFormat != "pdf" && article.captureIssue == null && captureWebUrl(article.url)) {
                        SecondaryButton("Sign in or capture page", onClick = model::openBrowser, enabled = enabled)
                    }
                }
            }
        }
    }
}

@Composable
private fun ItemCard(article: SharedArticle, preview: Boolean, colours: SheetColours) {
    val pdf = article.contentFormat == "pdf"
    Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(20.dp)).background(colours.card)
        .border(1.dp, colours.cardBorder, RoundedCornerShape(20.dp)).padding(16.dp).semantics(mergeDescendants = true) {},
        verticalArrangement = Arrangement.spacedBy(14.dp)) {
        Row(horizontalArrangement = Arrangement.spacedBy(14.dp)) {
            Column(Modifier.size(width = 52.dp, height = 64.dp).clip(RoundedCornerShape(10.dp))
                .background(MaterialTheme.colorScheme.primaryContainer).clearAndSetSemantics {},
                horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
                Icon(if (pdf) Icons.Outlined.Description else Icons.AutoMirrored.Outlined.Article, contentDescription = null,
                    tint = MaterialTheme.colorScheme.onPrimaryContainer)
                Text(if (pdf) "PDF" else "PAGE", style = MaterialTheme.typography.labelSmall, fontWeight = FontWeight.SemiBold,
                    color = MaterialTheme.colorScheme.onPrimaryContainer)
            }
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(article.title ?: if (pdf) pdfFileName(article.url) else sourceHost(article.url) ?: article.url,
                    style = MaterialTheme.typography.titleMedium)
                Text(if (pdf) pdfSource(article.url) else sourceHost(article.url)?.let { "Article from $it" } ?: article.url,
                    style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
        if (preview) article.preview?.let {
            HorizontalDivider(color = colours.cardBorder)
            Text(it, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 3, overflow = TextOverflow.Ellipsis,
                modifier = Modifier.semantics { contentDescription = "Article begins: $it" })
        }
    }
}

@Composable
private fun Status(icon: ImageVector, text: String) {
    Row(Modifier.padding(horizontal = 4.dp).semantics(mergeDescendants = true) { liveRegion = LiveRegionMode.Polite },
        horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        Icon(icon, contentDescription = null, tint = MaterialTheme.colorScheme.primary, modifier = Modifier.size(20.dp))
        Text(text, style = MaterialTheme.typography.bodyLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
private fun Notice(icon: ImageVector, text: String, container: Color, content: Color) {
    Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(16.dp)).background(container).padding(horizontal = 16.dp, vertical = 14.dp)
        .semantics(mergeDescendants = true) { liveRegion = LiveRegionMode.Polite },
        horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        Icon(icon, contentDescription = null, tint = content, modifier = Modifier.size(20.dp))
        Text(text, style = MaterialTheme.typography.bodyLarge, color = content)
    }
}

private val buttonText @Composable get() = MaterialTheme.typography.titleMedium

@Composable
private fun PrimaryButton(label: String, onClick: () -> Unit, enabled: Boolean = true) {
    Button(onClick = onClick, Modifier.fillMaxWidth().heightIn(min = 56.dp), enabled = enabled) { Text(label, style = buttonText) }
}

@Composable
private fun SecondaryButton(label: String, onClick: () -> Unit, enabled: Boolean = true) {
    TextButton(onClick = onClick, Modifier.fillMaxWidth().heightIn(min = 48.dp), enabled = enabled) { Text(label, style = buttonText) }
}

private class SheetColours(val sheet: Color, val card: Color, val cardBorder: Color,
    val warningContainer: Color, val onWarningContainer: Color, val errorContainer: Color, val onErrorContainer: Color)

@Composable
private fun sheetColours(): SheetColours = if (MaterialTheme.colorScheme.surface.luminance() < 0.5f) SheetColours(
    sheet = Color(0xFF171A20), card = Color(0xFF22262E), cardBorder = Color(0xFF353A45),
    warningContainer = Color(0xFF3D2E10), onWarningContainer = Color(0xFFFFDEA6),
    errorContainer = Color(0xFF4A1A17), onErrorContainer = Color(0xFFFFDAD5))
else SheetColours(
    sheet = Color(0xFFF4F5F9), card = Color.White, cardBorder = Color(0xFFE1E3EA),
    warningContainer = Color(0xFFFFF1D6), onWarningContainer = Color(0xFF4A3200),
    errorContainer = Color(0xFFFCE8E6), onErrorContainer = Color(0xFF5C1410))

private fun sourceHost(url: String): String? = runCatching { java.net.URI(url).host?.removePrefix("www.") }.getOrNull()?.takeIf { it.isNotBlank() }

/** A shared PDF link has no readable preview, so the sheet names the file and where it comes from. */
internal fun pdfFileName(url: String): String = runCatching {
    java.net.URI(url).path.substringAfterLast('/').takeIf { it.isNotBlank() }
}.getOrNull() ?: "PDF document"

internal fun pdfSource(url: String): String = sourceHost(url)?.let { "PDF from $it" } ?: "PDF document"
