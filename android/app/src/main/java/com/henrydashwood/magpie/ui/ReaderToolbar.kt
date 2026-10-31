package com.henrydashwood.magpie.ui

import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.OpenInNew
import androidx.compose.material.icons.rounded.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.unit.dp
import androidx.compose.foundation.layout.size
import com.henrydashwood.magpie.data.LibraryItem
import com.henrydashwood.magpie.data.ContentKind
import com.henrydashwood.magpie.sharing.articlePdfShareIntent
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.launch

/** Shared by article and recorded-episode pages; browser actions accept only web URLs. */
@Composable
fun ReaderToolbarActions(item: LibraryItem, playing: Boolean, searching: Boolean, togglePlayback: () -> Unit,
    toggleFind: () -> Unit, launchIntent: ((Intent) -> Unit)? = null, onAsk: () -> Unit = {},
    download: (@Composable () -> Unit)? = null, exportPDF: (suspend () -> Uri)? = null,
    shareSession: String? = null) {
    val context = LocalContext.current
    var message by rememberSaveable(item.id) { mutableStateOf<String?>(null) }
    val original = remember(item.originalUrl) {
        item.originalUrl?.let(Uri::parse)?.takeIf { it.scheme in listOf("https", "http") && !it.host.isNullOrBlank() }
    }
    fun launch(intent: Intent) {
        try { if (launchIntent != null) launchIntent(intent) else context.startActivity(intent) }
        catch (_: ActivityNotFoundException) { message = "No app is available to open this action." }
    }
    IconButton(onClick = togglePlayback) {
        Icon(if (playing) Icons.Rounded.Pause else Icons.Rounded.PlayArrow, if (playing) "Pause" else "Listen")
    }
    // As on iOS, a podcast episode's web page is rarely wanted and the bar has no room for both:
    // downloading takes its place, and the link stays reachable through Share.
    if (download != null) download()
    // Opening the original needs a web page; sharing a parsed article does not.
    if (original != null) {
        if (download == null) IconButton(onClick = { launch(Intent(Intent.ACTION_VIEW, original)) }) {
            Icon(Icons.AutoMirrored.Rounded.OpenInNew, "Open the original")
        }
    }
    key(item.id, item.contentId, item.contentVersion, shareSession) {
        ReaderShareAction(item, original, exportPDF, ::launch)
    }
    IconButton(onClick = toggleFind) {
        Icon(if (searching) Icons.Rounded.Close else Icons.Rounded.Search, if (searching) "Close search" else "Find in this page")
    }
    AskMagpieButton(onAsk)
    if (message != null) AlertDialog(onDismissRequest = { message = null }, title = { Text("Could not open") },
        text = { Text(message!!) }, confirmButton = { TextButton(onClick = { message = null }) { Text("Close") } })
}

@Composable
private fun ReaderShareAction(item: LibraryItem, original: Uri?, exportPDF: (suspend () -> Uri)?, launch: (Intent) -> Unit) {
    val canExport = item.kind == ContentKind.Article && exportPDF != null
    if (original == null && !canExport) return
    val scope = rememberCoroutineScope()
    var menu by remember { mutableStateOf(false) }
    var busy by remember { mutableStateOf(false) }
    var failure by remember { mutableStateOf<String?>(null) }
    fun shareLink() {
        val url = original ?: return
        val share = Intent(Intent.ACTION_SEND).apply {
            type = "text/plain"
            putExtra(Intent.EXTRA_SUBJECT, item.title)
            putExtra(Intent.EXTRA_TITLE, item.title)
            putExtra(Intent.EXTRA_TEXT, url.toString())
        }
        launch(Intent.createChooser(share, item.title))
    }
    fun pdf() {
        if (busy || exportPDF == null) return
        busy = true
        failure = null
        scope.launch {
            try {
                val uri = exportPDF()
                currentCoroutineContext().ensureActive()
                launch(articlePdfShareIntent(uri, item.title))
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (error: Exception) { failure = error.message ?: "The PDF couldn’t be prepared. Please try again." }
            finally { busy = false }
        }
    }
    val ready = item.textLoaded && item.text.isNotBlank()
    IconButton(onClick = {
        if (original != null && canExport) menu = true
        else if (canExport) pdf() else shareLink()
    }, enabled = !busy && (original != null || ready), modifier = Modifier.semantics {
        contentDescription = "Share article"
        stateDescription = if (busy) "Preparing PDF" else if (!ready && original == null) "Article is loading" else ""
    }) {
        if (busy) CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp)
        else Icon(Icons.Rounded.Share, null)
        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
            if (original != null) DropdownMenuItem(text = { Text("Share link") }, onClick = { menu = false; shareLink() })
            DropdownMenuItem(text = { Text("Export as PDF") }, enabled = ready, onClick = { menu = false; pdf() })
        }
    }
    if (failure != null) AlertDialog(onDismissRequest = { failure = null },
        title = { Text("Could not export PDF") }, text = { Text(failure!!) },
        confirmButton = { TextButton(onClick = { failure = null; pdf() }) { Text("Try again") } },
        dismissButton = { TextButton(onClick = { failure = null }) { Text("Cancel") } })
}
