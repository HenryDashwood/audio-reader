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
    toggleFind: () -> Unit, launchIntent: ((Intent) -> Unit)? = null, onAsk: () -> Unit = {}) {
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
    // As on iOS, both need a web page, so an article without one shows neither.
    if (original != null) {
        IconButton(onClick = { launch(Intent(Intent.ACTION_VIEW, original)) }) {
            Icon(Icons.AutoMirrored.Rounded.OpenInNew, "Open the original")
        }
        IconButton(onClick = {
            val share = Intent(Intent.ACTION_SEND).apply {
                type = "text/plain"
                putExtra(Intent.EXTRA_SUBJECT, item.title)
                putExtra(Intent.EXTRA_TITLE, item.title)
                putExtra(Intent.EXTRA_TEXT, original.toString())
            }
            launch(Intent.createChooser(share, item.title))
        }) { Icon(Icons.Rounded.Share, "Share article") }
    }
    IconButton(onClick = toggleFind) {
        Icon(if (searching) Icons.Rounded.Close else Icons.Rounded.Search, if (searching) "Close search" else "Find in this page")
    }
    AskMagpieButton(onAsk)
    if (message != null) AlertDialog(onDismissRequest = { message = null }, title = { Text("Could not open") },
        text = { Text(message!!) }, confirmButton = { TextButton(onClick = { message = null }) { Text("Close") } })
}
