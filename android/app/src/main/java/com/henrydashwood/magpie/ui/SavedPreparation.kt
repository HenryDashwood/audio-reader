package com.henrydashwood.magpie.ui

import android.content.Intent
import androidx.core.net.toUri
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.*
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.henrydashwood.magpie.MagpieModel
import com.henrydashwood.magpie.data.*
import java.net.URI

@Composable
fun SavedPreparationStatus(model: MagpieModel) {
    val state by model.savedPreparation.state.collectAsStateWithLifecycle()
    val deviceLinks by model.deviceLinks.collectAsStateWithLifecycle()
    val importing by model.importingLinks.collectAsStateWithLifecycle()
    var reviewing by rememberSaveable(state.revision) { mutableStateOf(false) }
    Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        if (state.busy) {
            LinearProgressIndicator(Modifier.fillMaxWidth())
            Text(if (state.itemId != null) "Preparing article…" else "Syncing saved links…", Modifier.semantics { liveRegion = LiveRegionMode.Polite })
        }
        state.error?.let { Text(it, color = MaterialTheme.colorScheme.error, modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite }) }
        if (state.pending.isNotEmpty()) TextButton(onClick = model.savedPreparation::sync, enabled = !state.busy) { Text("Sync saved links") }
        if (deviceLinks.isNotEmpty()) {
            Text("${deviceLinks.size} links saved before signing in")
            TextButton(onClick = { reviewing = true }, enabled = !state.busy && !importing) { Text("Review device links") }
        }
    }
    if (reviewing) AlertDialog(onDismissRequest = { reviewing = false }, title = { Text("Save device links to this account?") },
        text = { Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text("These links were saved before signing in. Importing moves them to your current account’s pending links and prepares them for Saved.")
            deviceLinks.forEach { Text(it) }
        } },
        confirmButton = { TextButton(onClick = { reviewing = false; model.importDeviceLinks() }, enabled = !state.busy && !importing && state.owner != null) { Text("Import links") } },
        dismissButton = { TextButton(onClick = { reviewing = false }) { Text("Cancel") } })
}

@Composable
fun SavedPendingRow(article: PendingArticle, model: MagpieModel) {
    val state by model.savedPreparation.state.collectAsStateWithLifecycle()
    Column(Modifier.fillMaxWidth().padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(URI(article.url).host, style = MaterialTheme.typography.titleMedium)
        Text(article.url)
        Text("Saved on this device · Waiting to sync", style = MaterialTheme.typography.bodySmall)
        TextButton(onClick = { model.savedPreparation.remove(article) }, enabled = !state.busy,
            modifier = Modifier.semantics { contentDescription = "Remove saved link ${article.url}" }) { Text("Remove saved link") }
    }
}

@Composable
fun SavedArticlePreparation(item: LibraryItem, model: MagpieModel) {
    val state by model.savedPreparation.state.collectAsStateWithLifecycle()
    val context = LocalContext.current
    var openError by remember(item.id) { mutableStateOf<String?>(null) }
    Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
        item.captureError?.let { raw ->
            // The shared backend sometimes includes Safari-specific recovery advice.
            val message = if (raw.contains("Safari")) "The link is saved, but Magpie could not retrieve the full article. Try again later or capture the page in Magpie." else raw
            Text(message, Modifier.semantics { liveRegion = LiveRegionMode.Polite })
            TextButton(onClick = { model.savedPreparation.retry(item) }, enabled = !state.busy,
                modifier = Modifier.semantics { contentDescription = "Retry preparing ${item.title}" }) { Text("Retry") }
            if (item.originalUrl != null) TextButton(onClick = {
                try { context.startActivity(Intent(Intent.ACTION_VIEW, item.originalUrl.toUri())) }
                catch (_: android.content.ActivityNotFoundException) { openError = "No browser is available to open the original page." }
            }) { Text("Open original") }
            // Recovery only when the server could not read the page; otherwise it lives in the row's menu.
            if (item.originalUrl != null) TextButton(onClick = { captureSavedPage(context, item) }, enabled = !state.busy,
                modifier = Modifier.semantics { contentDescription = "Capture page for ${item.title}" }) { Text("Capture page") }
        }
        openError?.let { Text(it, Modifier.semantics { liveRegion = LiveRegionMode.Polite }) }
    }
}

/** Opens the page inside Magpie, so she can sign in to the site and save the visible article. */
fun captureSavedPage(context: android.content.Context, item: LibraryItem) {
    context.startActivity(Intent(context, com.henrydashwood.magpie.sharing.ShareActivity::class.java).apply {
        action = Intent.ACTION_SEND; type = "text/plain"
        putExtra(Intent.EXTRA_TEXT, item.originalUrl); putExtra(Intent.EXTRA_SUBJECT, item.title)
    })
}

@Composable
fun ReplaceSavedTextDialog(model: MagpieModel) {
    val state by model.savedPreparation.state.collectAsStateWithLifecycle()
    val item = state.replacement ?: return
    AlertDialog(onDismissRequest = model.savedPreparation::cancelReplacement,
        title = { Text("Replace saved text?") },
        text = { Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text(item.title)
            Text("Download a fresh copy from the original link. If the text changes, listening starts from the beginning. If it fails, your current copy is kept.")
        } },
        confirmButton = { TextButton(onClick = model.savedPreparation::replace, enabled = !state.busy) { Text("Replace") } },
        dismissButton = { TextButton(onClick = model.savedPreparation::cancelReplacement, enabled = !state.busy) { Text("Cancel") } })
}
