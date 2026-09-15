package com.henrydashwood.magpie.ui

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.*
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.henrydashwood.magpie.MagpieModel
import com.henrydashwood.magpie.data.LibraryFeed

@Composable
fun SourceManagementMenu(model: MagpieModel, feed: LibraryFeed) {
    val library by model.libraryState.collectAsStateWithLifecycle()
    val state by model.sourceManager.state.collectAsStateWithLifecycle()
    var expanded by remember(feed.id) { mutableStateOf(false) }
    Box {
        FilledTonalIconButton(enabled = !state.busy, onClick = { expanded = true }) { Icon(Icons.Rounded.MoreVert, "Manage ${feed.title}") }
        DropdownMenu(expanded, onDismissRequest = { expanded = false }) {
            DropdownMenuItem(text = { Text("Manage sources") }, leadingIcon = { Icon(Icons.Rounded.Link, null) },
                onClick = { expanded = false; model.sourceManager.open(feed, library.revision) })
            HorizontalDivider()
            DropdownMenuItem(text = { Text("Unsubscribe", color = MaterialTheme.colorScheme.error) },
                leadingIcon = { Icon(Icons.Rounded.RemoveCircleOutline, null) },
                onClick = { expanded = false; model.sourceManager.unsubscribe(feed, library.revision) })
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SourceManagementDialog(model: MagpieModel) {
    val manager = model.sourceManager
    val state by manager.state.collectAsStateWithLifecycle()
    val feed = state.feed ?: return
    if (!state.showing) return
    Dialog(onDismissRequest = manager::close, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Scaffold(topBar = { TopAppBar(title = { Text("Manage sources") }, actions = {
            IconButton(enabled = !state.busy, onClick = manager::close) { Icon(Icons.Rounded.Close, "Close source management") }
        }) }) { padding ->
            Column(Modifier.fillMaxSize().padding(padding)) {
                if (state.busy) LinearProgressIndicator(Modifier.fillMaxWidth().semantics { contentDescription = "Updating sources" })
                LazyColumn(Modifier.fillMaxSize().testTag("feed-sources-list"), contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    item { Text("Combine sources of the same publication into one list. Matching articles appear once, using the copy with the most text, and share reading progress.") }
                    item { Text("Separating a source returns it to Following with its reading progress.") }
                    state.notice?.let { message -> item { Text(message, Modifier.semantics { liveRegion = LiveRegionMode.Polite }) } }
                    state.error?.let { error -> item {
                        Text(error, color = MaterialTheme.colorScheme.error, modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite })
                        TextButton(onClick = manager::reload, enabled = !state.busy) { Text("Try again") }
                    } }
                    item { Text("Sources in ${feed.title}", style = MaterialTheme.typography.titleMedium, modifier = Modifier.semantics { heading() }) }
                    items(state.sources, key = { "source:${it.id}" }) { source ->
                        Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                            Text(source.title, style = MaterialTheme.typography.titleMedium)
                            Text(source.location)
                            if (source.failing) Text("This source is not updating")
                            if (source.primary) Text("Used for the publication’s name and artwork", style = MaterialTheme.typography.bodySmall)
                            else TextButton(enabled = !state.busy, onClick = { manager.separate(source) },
                                modifier = Modifier.semantics { contentDescription = "Separate ${source.title}, ${source.location}" }) { Text("Separate source") }
                        }
                        HorizontalDivider()
                    }
                    item { Text("Combine with a subscription", style = MaterialTheme.typography.titleMedium, modifier = Modifier.semantics { heading() }) }
                    if (state.loaded && state.available.isEmpty()) item { Text("No other subscriptions to combine.") }
                    items(state.available, key = { "available:${it.id}" }) { other ->
                        TextButton(enabled = !state.busy, onClick = { manager.combine(other) }, modifier = Modifier.fillMaxWidth()
                            .semantics { contentDescription = "Combine ${other.title} with ${feed.title}" }) {
                            Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                                Text(other.title)
                                other.sourceDetails.firstOrNull { it.primary }?.let { Text(it.location, style = MaterialTheme.typography.bodySmall) }
                            }
                        }
                    }
                    item { Text("To use another feed, subscribe to it first. Combining a publication includes all its sources.") }
                    item {
                        HorizontalDivider()
                        if (state.sources.size > 1 || feed.sourceDetails.size > 1) Text("Unsubscribing from this publication stops following all its sources.", Modifier.padding(top = 12.dp))
                        if (feed.forwarded) Text("This newsletter is forwarded from your email. Unsubscribing hides it in Magpie; remove the forwarding rule in your email account to stop the emails.", Modifier.padding(top = 12.dp))
                        TextButton(enabled = !state.busy, onClick = { manager.unsubscribe(feed, state.sessionRevision) },
                            modifier = Modifier.semantics { contentDescription = "Unsubscribe from ${feed.title}" }) { Text("Unsubscribe", color = MaterialTheme.colorScheme.error) }
                    }
                }
            }
        }
    }
}
