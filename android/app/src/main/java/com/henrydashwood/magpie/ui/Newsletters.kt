package com.henrydashwood.magpie.ui

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Intent
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.*
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.henrydashwood.magpie.MagpieModel
import com.henrydashwood.magpie.data.*

@Composable
fun NewsletterAddressSection(model: MagpieModel) {
    val library by model.libraryState.collectAsStateWithLifecycle()
    val state by model.newsletters.state.collectAsStateWithLifecycle()
    val speaking by model.newsletterSpeech.speaking.collectAsStateWithLifecycle()
    LaunchedEffect(library.revision, library.live, state.revision) {
        if (library.live && state.revision == library.revision) model.newsletters.loadAddress()
    }
    Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        if (!library.live) Text("Sign in to get your Magpie newsletter address.")
        else if (state.revision == library.revision) {
            if (state.loadingAddress) Text("Getting your newsletter address…", Modifier.semantics { liveRegion = LiveRegionMode.Polite })
            state.addressError?.let {
                Text(it, color = MaterialTheme.colorScheme.error, modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite })
                TextButton(onClick = model.newsletters::loadAddress) { Text("Try again") }
            }
            state.address?.let { address ->
                SelectionContainer {
                    Text(address.address, Modifier.testTag("newsletter-address").clearAndSetSemantics {
                        contentDescription = "Your newsletter address is ${address.spoken}"
                    })
                }
                TextButton(onClick = { model.readNewsletterAddress(false) }, enabled = !speaking) { Text("Read address aloud") }
                TextButton(onClick = { model.readNewsletterAddress(true) }, enabled = !speaking) { Text("Spell address") }
                if (speaking) TextButton(onClick = { model.newsletterSpeech.stop() }) { Text("Stop reading address") }
                NewsletterAddressActions(address.address) { model.libraryState.value.live && model.libraryState.value.revision == state.revision }
            }
        }
    }
}

@Composable
fun NewsletterAddressActions(address: String, valid: () -> Boolean) {
    val context = LocalContext.current
    val haptic = LocalHapticFeedback.current
    var copied by remember(address) { mutableStateOf(false) }
    var error by remember(address) { mutableStateOf<String?>(null) }
    Column {
        TextButton(onClick = {
            if (valid()) {
                context.getSystemService(ClipboardManager::class.java).setPrimaryClip(ClipData.newPlainText("Magpie newsletter address", address))
                copied = true; haptic.performHapticFeedback(HapticFeedbackType.LongPress)
            }
        }) { Text(if (copied) "Address copied" else "Copy address", Modifier.semantics { liveRegion = LiveRegionMode.Polite }) }
        TextButton(onClick = {
            if (valid()) try {
                context.startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).apply {
                    type = "text/plain"; putExtra(Intent.EXTRA_TEXT, address); putExtra(Intent.EXTRA_SUBJECT, "My Magpie newsletter address")
                }, "Share newsletter address"))
            } catch (_: android.content.ActivityNotFoundException) { error = "No app is available to share this address. You can copy it instead." }
        }) { Text("Share address") }
        error?.let { Text(it, Modifier.semantics { liveRegion = LiveRegionMode.Polite }, color = MaterialTheme.colorScheme.error) }
    }
}

fun LazyListScope.pendingNewsletters(model: MagpieModel, state: NewsletterState) {
    if (state.pending.isNotEmpty()) {
        item("newsletter-heading") { Text("Waiting for your answer", Modifier.padding(16.dp).semantics { heading() }, style = MaterialTheme.typography.titleMedium) }
        items(state.pending, key = { "newsletter:${it.id}" }) { sender ->
            PendingNewsletterRow(sender, state.busyId != null, { model.newsletters.approve(sender) }, { model.newsletters.block(sender) })
        }
        item("newsletter-explanation") { Text("Follow a sender to put its messages in Latest and receive what comes next. Blocking deletes its messages and drops future emails.", Modifier.padding(16.dp), style = MaterialTheme.typography.bodySmall) }
    }
    state.pendingError?.let { message -> item("newsletter-error") {
        Column(Modifier.padding(16.dp)) {
            Text(message, Modifier.semantics { liveRegion = LiveRegionMode.Polite }, color = MaterialTheme.colorScheme.error)
            TextButton(onClick = model.newsletters::loadPending, enabled = state.busyId == null) { Text("Retry newsletter senders") }
        }
    } }
}

@Composable
private fun PendingNewsletterRow(item: PendingNewsletter, busy: Boolean, follow: () -> Unit, block: () -> Unit) {
    var confirming by remember(item.sessionRevision, item.id) { mutableStateOf(false) }
    Column(Modifier.fillMaxWidth().padding(16.dp).testTag("newsletter-${item.id}"), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(item.title, style = MaterialTheme.typography.titleMedium)
        Text(item.senderAddress)
        Text(item.messageCountLabel + (item.latestTitle?.let { ", latest: $it" } ?: ""))
        // A vertical arrangement keeps both actions reachable at large text sizes.
        Button(onClick = follow, enabled = !busy, modifier = Modifier.semantics { contentDescription = "Follow ${item.title}" }) { Text("Follow") }
        TextButton(onClick = { confirming = true }, enabled = !busy, modifier = Modifier.semantics { contentDescription = "Block ${item.title}" }) { Text("Block", color = MaterialTheme.colorScheme.error) }
    }
    if (confirming) AlertDialog(onDismissRequest = { confirming = false }, title = { Text("Block this sender?") },
        text = { Text("Everything ${item.title} has sent is deleted, and anything it sends later is dropped without being kept.") },
        confirmButton = { TextButton(onClick = { confirming = false; block() }, enabled = !busy) { Text("Block ${item.title}", color = MaterialTheme.colorScheme.error) } },
        dismissButton = { TextButton(onClick = { confirming = false }) { Text("Cancel") } })
}
