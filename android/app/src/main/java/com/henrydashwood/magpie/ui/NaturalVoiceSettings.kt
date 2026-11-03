package com.henrydashwood.magpie.ui

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.henrydashwood.magpie.MagpieModel
import com.henrydashwood.magpie.playback.NaturalVoiceDownload.State

/** Settings' natural voice: download it, choose who reads articles, remove it. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun NaturalVoiceSection(model: MagpieModel, selected: String?) {
    val state by model.naturalVoice.collectAsStateWithLifecycle()
    var choosing by rememberSaveable { mutableStateOf(false) }
    var confirmingRemove by rememberSaveable { mutableStateOf(false) }
    var downloaded by rememberSaveable { mutableStateOf(false) }
    val confirmation = rememberLauncherForActivityResult(ActivityResultContracts.StartIntentSenderForResult()) {}
    LaunchedEffect(model) { model.refreshNaturalVoice() }
    var previous by remember { mutableStateOf<State>(State.Checking) }
    LaunchedEffect(state) {
        if (state is State.Installed && previous is State.Downloading) downloaded = true
        previous = state
    }
    SettingsSection("Natural Voice", "A more natural voice for reading articles. It runs on this phone, so it works offline once downloaded. Magpie’s spoken replies keep the Google voice.") {
        when (val current = state) {
            State.Checking -> ListItem(headlineContent = { Text("Checking…") })
            is State.NotInstalled -> SettingsAction("Download natural voice (${current.bytes?.let(::megabytes) ?: "about 290 MB"})", Icons.Rounded.Download, model::downloadNaturalVoice)
            is State.Unavailable -> SettingsFootnote(current.message)
            State.Waiting -> {
                ListItem(headlineContent = { Text("Waiting to download…") }, supportingContent = { LinearProgressIndicator(Modifier.fillMaxWidth().padding(top = 8.dp)) })
                SettingsAction("Cancel download", Icons.Rounded.Close, model::cancelNaturalVoice)
            }
            is State.Downloading -> {
                val percent = "${(current.fraction * 100).toInt()}%"
                ListItem(headlineContent = { Text("Downloading the natural voice") }, trailingContent = { Text(percent) },
                    supportingContent = { LinearProgressIndicator({ current.fraction }, Modifier.fillMaxWidth().padding(top = 8.dp)) })
                SettingsAction("Cancel download", Icons.Rounded.Close, model::cancelNaturalVoice)
            }
            State.NeedsConfirmation, State.WaitingForWifi -> {
                SettingsFootnote(if (current == State.WaitingForWifi) "The download will start on Wi-Fi." else "The natural voice is a large download.")
                SettingsAction("Download over mobile data", Icons.Rounded.SignalCellularAlt) { model.confirmNaturalVoice(confirmation) }
                SettingsAction("Cancel download", Icons.Rounded.Close, model::cancelNaturalVoice)
            }
            is State.Installed -> {
                val chosen = current.voices.find { it.id == selected }
                ListItem(headlineContent = { Text("Read articles with") }, supportingContent = { Text(chosen?.label ?: "Google voice") },
                    trailingContent = { Icon(Icons.Rounded.ChevronRight, null) },
                    modifier = Modifier.clickable(onClickLabel = "Choose who reads articles") { choosing = true }.testTag("natural-voice-setting"))
                if (downloaded) SettingsFootnote("The natural voice has downloaded.", announced = true)
                SettingsAction("Remove natural voice", Icons.Rounded.Delete) { confirmingRemove = true }
            }
            is State.Failed -> {
                SettingsFootnote(current.message, error = true)
                SettingsAction("Try again", Icons.Rounded.Refresh, model::downloadNaturalVoice)
            }
        }
    }
    val installed = state as? State.Installed
    if (choosing && installed != null) ModalBottomSheet(onDismissRequest = { choosing = false }, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
        Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp), horizontalArrangement = Arrangement.SpaceBetween) {
            Text("Read articles with", Modifier.padding(vertical = 12.dp).semantics { heading() }, style = MaterialTheme.typography.titleLarge)
            IconButton(onClick = { choosing = false }) { Icon(Icons.Rounded.Close, "Close") }
        }
        LazyColumn(Modifier.fillMaxWidth().heightIn(max = 440.dp).testTag("natural-voice-list")) {
            item { VoiceChoice("Google voice", "The voice chosen below", selected == null) { model.selectNaturalVoice(null); choosing = false } }
            items(installed.voices, key = { it.id }) { voice ->
                VoiceChoice(voice.label, "Natural voice", selected == voice.id) { model.selectNaturalVoice(voice); choosing = false }
            }
        }
    }
    if (confirmingRemove) AlertDialog(onDismissRequest = { confirmingRemove = false },
        title = { Text("Remove the natural voice?") },
        text = { Text("Articles will be read with the Google voice. You can download it again at any time.") },
        confirmButton = { TextButton(onClick = { confirmingRemove = false; downloaded = false; model.removeNaturalVoice() }) { Text("Remove", color = MaterialTheme.colorScheme.error) } },
        dismissButton = { TextButton(onClick = { confirmingRemove = false }) { Text("Cancel") } })
}

private fun megabytes(bytes: Long) = "${(bytes + 500_000) / 1_000_000} MB"
