package com.henrydashwood.magpie.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.rounded.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.*
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.henrydashwood.magpie.MagpieApplication
import com.henrydashwood.magpie.MagpieModel
import com.henrydashwood.magpie.data.*

/** The download state of a row, or null; read without a model so any row can show it. */
@Composable
internal fun downloadLabel(item: LibraryItem): String? {
    val application = LocalContext.current.applicationContext as? MagpieApplication ?: return null
    val records by application.downloads.records.collectAsStateWithLifecycle()
    return records[item.id]?.statusLabel
}

/** Downloads an episode, shows how it is going, and removes it again. */
@Composable
fun DownloadButton(model: MagpieModel, item: LibraryItem, modifier: Modifier = Modifier) {
    val records by model.downloads.records.collectAsStateWithLifecycle()
    val record = records[item.id]
    var confirmingRemoval by remember(item.id) { mutableStateOf(false) }
    val label = when (record?.status) {
        is DownloadStatus.Queued, is DownloadStatus.Downloading -> "Cancel download"
        DownloadStatus.Downloaded -> "Remove download"
        is DownloadStatus.Failed -> "Retry download"
        null -> "Download"
    }
    IconButton(onClick = {
        when (record?.status) {
            is DownloadStatus.Queued, is DownloadStatus.Downloading -> model.removeDownload(item, cancelled = true)
            DownloadStatus.Downloaded -> confirmingRemoval = true
            else -> model.requestDownload(listOf(item))
        }
    }, modifier = modifier.semantics { record?.let { stateDescription = it.statusLabel } }) {
        when (val status = record?.status) {
            is DownloadStatus.Queued, is DownloadStatus.Downloading -> Box(contentAlignment = Alignment.Center) {
                val progress = (status as? DownloadStatus.Downloading)?.progress?.toFloat()
                if (progress != null && progress > 0f) CircularProgressIndicator(progress = { progress }, Modifier.size(24.dp), strokeWidth = 2.5.dp)
                else CircularProgressIndicator(Modifier.size(24.dp), strokeWidth = 2.5.dp)
                Icon(Icons.Rounded.Stop, label, Modifier.size(12.dp))
            }
            DownloadStatus.Downloaded -> Icon(Icons.Rounded.DownloadDone, label)
            is DownloadStatus.Failed -> Icon(Icons.Rounded.ErrorOutline, label)
            null -> Icon(Icons.Rounded.Download, label)
        }
    }
    if (confirmingRemoval) AlertDialog(onDismissRequest = { confirmingRemoval = false },
        title = { Text("Remove the download of ${item.title}?") },
        text = { Text("You can still play it with a connection.") },
        confirmButton = { TextButton(onClick = { confirmingRemoval = false; model.removeDownload(item) }) { Text("Remove download") } },
        dismissButton = { TextButton(onClick = { confirmingRemoval = false }) { Text("Cancel") } })
}

/** Asks before going over the limit or using mobile data, or explains why nothing happened. */
@Composable
fun DownloadPromptDialog(model: MagpieModel) {
    val prompt by model.downloadPrompt.collectAsStateWithLifecycle()
    val current = prompt ?: return
    val confirmation = current.confirmation
    AlertDialog(onDismissRequest = { model.answerDownloadPrompt(null) },
        title = { Text(current.title) }, text = { Text(current.message) },
        confirmButton = {
            if (confirmation == null) TextButton(onClick = { model.answerDownloadPrompt(null) }) { Text("OK") }
            else TextButton(onClick = { model.answerDownloadPrompt(false) }) {
                Text(if (confirmation.usesMobileData) "Download now" else "Download anyway")
            }
        },
        dismissButton = if (confirmation == null) null else { {
            Row {
                if (confirmation.usesMobileData) TextButton(onClick = { model.answerDownloadPrompt(true) }) { Text("Wait for Wi-Fi") }
                TextButton(onClick = { model.answerDownloadPrompt(null) }) { Text("Cancel") }
            }
        } })
}

/** Settings → Downloads: how much may be kept, what arrives by itself, and what is here now. */
@Composable
fun DownloadsScreen(model: MagpieModel, onBack: () -> Unit) {
    val downloads = model.downloads
    val settings by downloads.settings.collectAsStateWithLifecycle()
    val records by downloads.records.collectAsStateWithLifecycle()
    val library by model.libraryState.collectAsStateWithLifecycle()
    var choosingLimit by remember { mutableStateOf(false) }
    var choosingPerShow by remember { mutableStateOf(false) }
    var confirmingRemoveAll by remember { mutableStateOf(false) }
    val sorted = remember(records) { downloads.sorted }
    val used = remember(records) { DownloadPolicy.used(records.values) }
    Scaffold(topBar = { Surface {
        Row(Modifier.fillMaxWidth().windowInsetsPadding(WindowInsets.statusBars).heightIn(min = 64.dp).padding(end = 16.dp),
            verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Rounded.ArrowBack, "Back") }
            Text("Downloads", Modifier.weight(1f).padding(vertical = 12.dp).semantics { heading() }, style = MaterialTheme.typography.titleLarge)
        }
    } }) { padding ->
        LazyColumn(Modifier.fillMaxSize().padding(padding).testTag("downloads-list"), contentPadding = PaddingValues(bottom = 24.dp)) {
            item {
                SettingsSection("Storage", top = 8.dp, footer = "When downloads reach the limit, Magpie removes episodes you have finished, then the oldest automatic downloads. Episodes you download yourself stay until you have heard them; Magpie asks before one takes you over the limit.") {
                    val limit = settings.limit
                    val summary = if (limit != null) "${formatBytes(used)} of ${formatBytes(limit)} used" else "${formatBytes(used)} used"
                    Column(Modifier.fillMaxWidth().padding(16.dp).semantics(mergeDescendants = true) { contentDescription = "Downloads use $summary" },
                        verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        Text(summary)
                        if (limit != null) LinearProgressIndicator(progress = { (used.toFloat() / limit).coerceIn(0f, 1f) }, Modifier.fillMaxWidth(),
                            color = if (used > limit) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.primary)
                    }
                    ListItem(headlineContent = { Text("Storage limit") },
                        trailingContent = { Text(DownloadSettings.limitLabel(settings.limitBytes), color = MaterialTheme.colorScheme.primary) },
                        modifier = Modifier.clickable(onClickLabel = "Change storage limit") { choosingLimit = true }.testTag("download-limit"))
                }
            }
            item {
                SettingsSection("Automatic Downloads", footer = "Magpie keeps the newest unplayed episodes of each show you follow, so they play without a connection. With Wi-Fi only on, new episodes wait for Wi-Fi, and Magpie asks before downloading anything you choose over mobile data. Finished episodes are removed a day later.") {
                    ListItem(headlineContent = { Text("Download new episodes") },
                        trailingContent = { Switch(settings.automatic, { downloads.updateSettings(settings.copy(automatic = it)) },
                            Modifier.semantics { contentDescription = "Download new episodes" }) })
                    if (settings.automatic) ListItem(headlineContent = { Text("Episodes per show") },
                        trailingContent = { Text("${settings.perShow}", color = MaterialTheme.colorScheme.primary) },
                        modifier = Modifier.clickable(onClickLabel = "Change episodes per show") { choosingPerShow = true })
                    ListItem(headlineContent = { Text("Use Wi-Fi only") },
                        trailingContent = { Switch(settings.wifiOnly, { downloads.updateSettings(settings.copy(wifiOnly = it)) },
                            Modifier.semantics { contentDescription = "Use Wi-Fi only" }) })
                }
            }
            item { Text("On this phone", Modifier.padding(start = 32.dp, top = 24.dp, bottom = 8.dp).semantics { heading() },
                style = MaterialTheme.typography.titleMedium, color = MaterialTheme.colorScheme.primary) }
            if (sorted.isEmpty()) item {
                Text("Nothing downloaded yet. Use the download button on an episode's page, or Download in an episode's actions.",
                    Modifier.padding(horizontal = 32.dp), color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            items(sorted, key = { it.id }) { record ->
                val item = library.items.firstOrNull { it.id == record.id } ?: record.episode.item()
                val details = listOfNotNull(
                    if (record.status == DownloadStatus.Downloaded) formatBytes(record.bytes) else "About ${formatBytes(record.bytes)}",
                    record.statusLabel, "Automatic".takeIf { record.origin == DownloadOrigin.Automatic }, "Finished".takeIf { record.playedAt != null },
                ).joinToString(" · ")
                ListItem(headlineContent = { Text(record.episode.title) },
                    supportingContent = {
                        Column {
                            Text(record.episode.source)
                            Text(details, style = MaterialTheme.typography.bodySmall)
                            (record.status as? DownloadStatus.Failed)?.let { Text(it.message, style = MaterialTheme.typography.bodySmall) }
                        }
                    },
                    trailingContent = {
                        Row {
                            if (record.status == DownloadStatus.Downloaded && library.items.any { it.id == record.id })
                                IconButton(onClick = { model.play(item) }) { Icon(Icons.Rounded.PlayCircleOutline, "Play ${record.episode.title}") }
                            if (record.status is DownloadStatus.Failed)
                                IconButton(onClick = { model.requestDownload(listOf(item)) }) { Icon(Icons.Rounded.Refresh, "Retry download: ${record.episode.title}") }
                            IconButton(onClick = { model.removeDownload(item, cancelled = record.status.active) }) {
                                Icon(Icons.Rounded.Delete, "${if (record.status.active) "Cancel" else "Remove"} download: ${record.episode.title}")
                            }
                        }
                    })
            }
            if (records.isNotEmpty()) item {
                TextButton(onClick = { confirmingRemoveAll = true }, Modifier.padding(horizontal = 16.dp, vertical = 8.dp)) {
                    Text("Remove all downloads", color = MaterialTheme.colorScheme.error)
                }
            }
        }
    }
    if (choosingLimit) ChoiceDialog("Storage limit", DownloadSettings.limitOptions, settings.limitBytes, DownloadSettings::limitLabel,
        { downloads.updateSettings(settings.copy(limitBytes = it)) }) { choosingLimit = false }
    if (choosingPerShow) ChoiceDialog("Episodes per show", DownloadSettings.perShowOptions, settings.perShow, { "$it" },
        { downloads.updateSettings(settings.copy(perShow = it)) }) { choosingPerShow = false }
    if (confirmingRemoveAll) AlertDialog(onDismissRequest = { confirmingRemoveAll = false },
        title = { Text("Remove all downloads?") }, text = { Text("Episodes will need a connection to play.") },
        confirmButton = { TextButton(onClick = { confirmingRemoveAll = false; downloads.removeAll() }) { Text("Remove all downloads") } },
        dismissButton = { TextButton(onClick = { confirmingRemoveAll = false }) { Text("Cancel") } })
    DownloadPromptDialog(model)
}
