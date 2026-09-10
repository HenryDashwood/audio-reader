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
import com.henrydashwood.magpie.data.LibraryItem

/** Shared by article and recorded-episode pages; browser actions accept only web URLs. */
@Composable
fun ReaderToolbarActions(item: LibraryItem, playing: Boolean, searching: Boolean, togglePlayback: () -> Unit,
    toggleFind: () -> Unit, launchIntent: ((Intent) -> Unit)? = null) {
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
    IconButton(enabled = original != null, onClick = { original?.let { launch(Intent(Intent.ACTION_VIEW, it)) } },
        modifier = Modifier.semantics { if (original == null) stateDescription = "This sample has no original web page" }) {
        Icon(Icons.AutoMirrored.Rounded.OpenInNew, "Open the original")
    }
    IconButton(onClick = {
        val share = Intent(Intent.ACTION_SEND).apply {
            type = "text/plain"
            putExtra(Intent.EXTRA_SUBJECT, item.title)
            putExtra(Intent.EXTRA_TITLE, item.title)
            // Bundled original samples have no public URL. Share their text without inventing a link.
            putExtra(Intent.EXTRA_TEXT, original?.toString() ?: "${item.title}\n${item.source} · Magpie sample\n\n${item.text}")
        }
        launch(Intent.createChooser(share, null))
    }) { Icon(Icons.Rounded.Share, if (original == null) "Share sample text" else "Share link") }
    IconButton(onClick = toggleFind) {
        Icon(if (searching) Icons.Rounded.Close else Icons.Rounded.Search, if (searching) "Close search" else "Find in this page")
    }
    AskMagpieButton()
    if (message != null) AlertDialog(onDismissRequest = { message = null }, title = { Text("Could not open") },
        text = { Text(message!!) }, confirmButton = { TextButton(onClick = { message = null }) { Text("Close") } })
}
