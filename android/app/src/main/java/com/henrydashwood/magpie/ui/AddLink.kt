package com.henrydashwood.magpie.ui

import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.*
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.henrydashwood.magpie.MagpieModel
import java.net.URI

@Composable
fun AddLinkButton(model: MagpieModel, onSaved: () -> Unit) {
    val library by model.libraryState.collectAsStateWithLifecycle()
    val capture by model.linkCapture.collectAsStateWithLifecycle()
    LaunchedEffect(capture.savedUrl) {
        if (capture.savedUrl != null) { onSaved(); model.acknowledgeSavedLink() }
    }
    IconButton(onClick = model::beginLinkCapture) { Icon(Icons.Rounded.Add, "Add link") }
    AddressCaptureDialog(capture, "Add link", "Web address", "https://example.com/article",
        if (library.live) "Save this article to your account so it is available on your other devices." else "The link is saved on this device. Preparing articles will be available when your account is connected.",
        model::closeLinkCapture, model::editLink, model::saveLink)
}

@Composable
fun AddSourceButton(model: MagpieModel, onSaved: () -> Unit) {
    val library by model.libraryState.collectAsStateWithLifecycle()
    val capture by model.sourceCapture.collectAsStateWithLifecycle()
    LaunchedEffect(capture.savedUrl) {
        if (capture.savedUrl != null) { onSaved(); model.acknowledgeSavedSource() }
    }
    IconButton(onClick = model::beginSourceCapture) { Icon(Icons.Rounded.Add, "Add sources") }
    AddressCaptureDialog(capture, "Add sources", "Feed or website address", "https://example.com/feed.xml",
        if (library.live) "Enter a direct RSS, Atom, or JSON feed address to follow it on all your devices. Website discovery and searching by name are not available here yet." else "The address is saved on this device. Finding feeds, searching by name, and subscribing will be available when your account is connected.",
        model::closeSourceCapture, model::editSource, model::saveSource)
}

@Composable
private fun AddressCaptureDialog(capture: com.henrydashwood.magpie.LinkCaptureState, title: String,
    addressLabel: String, placeholder: String, explanation: String, close: () -> Unit, edit: (String) -> Unit, save: () -> Unit) {
    if (capture.showing) AlertDialog(onDismissRequest = close, title = { Text(title) },
        text = {
            Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                OutlinedTextField(capture.url, edit, Modifier.fillMaxWidth(), label = { Text(addressLabel) },
                    placeholder = { Text(placeholder) }, singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri, autoCorrectEnabled = false),
                    enabled = !capture.saving, isError = capture.error != null)
                if (capture.error != null) Text(capture.error!!, color = MaterialTheme.colorScheme.error,
                    modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite })
                Text(explanation)
            }
        }, confirmButton = {
            TextButton(enabled = capture.url.isNotBlank() && !capture.saving, onClick = save) { Text(if (capture.saving) "Saving…" else "Save") }
        }, dismissButton = { TextButton(enabled = !capture.saving, onClick = close) { Text("Cancel") } })
}

@Composable
fun PendingLinkRow(url: String, isSource: Boolean = false, remove: () -> Unit) {
    var expanded by remember { mutableStateOf(false) }
    val removeLabel = if (isSource) "Remove feed address" else "Remove saved link"
    Box {
        ListItem(headlineContent = { Text(URI(url).host) }, supportingContent = {
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(url)
                Text(if (isSource) "Feed address · Waiting for account connection" else "Saved on this device · Waiting for account connection", style = MaterialTheme.typography.bodySmall)
            }
        }, modifier = Modifier.combinedClickable(onClick = { expanded = true }, onLongClick = { expanded = true }, onClickLabel = if (isSource) "Feed address actions" else "Saved link actions")
            .semantics { customActions = listOf(CustomAccessibilityAction(removeLabel) { remove(); true }) })
        DropdownMenu(expanded, onDismissRequest = { expanded = false }) {
            DropdownMenuItem(text = { Text(removeLabel) }, onClick = { expanded = false; remove() })
        }
    }
    HorizontalDivider(Modifier.padding(horizontal = 16.dp))
}
