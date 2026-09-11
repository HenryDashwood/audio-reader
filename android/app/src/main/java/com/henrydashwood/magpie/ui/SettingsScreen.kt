package com.henrydashwood.magpie.ui

import android.content.ActivityNotFoundException
import android.content.Intent
import android.provider.Settings
import android.speech.tts.TextToSpeech
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.automirrored.rounded.OpenInNew
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.*
import androidx.compose.ui.unit.dp
import androidx.core.net.toUri
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.henrydashwood.magpie.MagpieModel
import com.henrydashwood.magpie.data.playbackRates
import com.henrydashwood.magpie.data.ContentKind
import com.henrydashwood.magpie.playback.SpeechVoices

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(model: MagpieModel, onAccount: () -> Unit) {
    val library by model.libraryState.collectAsStateWithLifecycle()
    val preferences by model.settings.collectAsStateWithLifecycle()
    val voices by model.voices.collectAsStateWithLifecycle()
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    val context = LocalContext.current
    var showingVoices by rememberSaveable { mutableStateOf(false) }
    var linkError by rememberSaveable { mutableStateOf<String?>(null) }
    DisposableEffect(lifecycle, model) {
        val observer = LifecycleEventObserver { _, event ->
            when (event) {
                Lifecycle.Event.ON_RESUME -> model.refreshVoices()
                Lifecycle.Event.ON_PAUSE -> model.stopVoicePreview()
                else -> Unit
            }
        }
        lifecycle.addObserver(observer)
        onDispose { lifecycle.removeObserver(observer); model.closeVoiceSettings() }
    }
    fun open(intent: Intent) {
        try { context.startActivity(intent); linkError = null }
        catch (_: ActivityNotFoundException) { linkError = "No app is available to open this link." }
    }
    val selectedVoice = if (preferences.voiceId == null) "Automatic · English"
        else voices.voices.find { it.id == preferences.voiceId }?.label ?: if (voices.loading) "Loading voice…" else "Selected voice unavailable"
    LazyColumn(Modifier.fillMaxSize().testTag("settings-list")) {
        item { SettingsHeading("Playback Speed") }
        item { SpeedSetting("Podcasts", preferences.podcastSpeed) { model.setSpeed(ContentKind.Podcast, it) } }
        item { SpeedSetting("Articles", preferences.articleSpeed) { model.setSpeed(ContentKind.Article, it) } }
        item { SettingsFootnote("Magpie remembers separate speeds for recorded podcasts and articles read by the system voice.") }
        item { HorizontalDivider(); SettingsHeading("Voice") }
        item {
            ListItem(headlineContent = { Text("Voice") }, supportingContent = { Text(if (voices.loading) "Loading installed voices…" else selectedVoice) },
                trailingContent = { Icon(Icons.Rounded.ChevronRight, null) },
                modifier = Modifier.clickable(onClickLabel = "Choose voice") { showingVoices = true }.testTag("voice-setting"))
        }
        item {
            ListItem(headlineContent = { Text(if (voices.previewing) "Stop voice preview" else "Listen to voice") },
                leadingContent = { Icon(if (voices.previewing) Icons.Rounded.Stop else Icons.Rounded.PlayArrow, null) },
                modifier = Modifier.clickable(enabled = !voices.loading && voices.voices.isNotEmpty()) {
                    if (voices.previewing) model.stopVoicePreview() else model.previewVoice()
                })
        }
        if (voices.error != null) item { SettingsFootnote(voices.error!!, error = true) }
        item {
            SettingsAction("Download voices", Icons.Rounded.Download) {
                try { context.startActivity(Intent(TextToSpeech.Engine.ACTION_INSTALL_TTS_DATA).setPackage(SpeechVoices.ENGINE)) }
                catch (_: ActivityNotFoundException) { open(Intent(Settings.ACTION_SETTINGS)) }
            }
        }
        item { SettingsAction("Refresh voices", Icons.Rounded.Refresh, model::refreshVoices) }
        item { SettingsFootnote("Choose from installed offline Google voices. Download more voices in Android’s text-to-speech settings. A voice change applies the next time you start an article.") }
        item { HorizontalDivider(); SettingsHeading("Conversation") }
        item { SettingsFootnote("Voice conversations are not connected in this preview. Keep listening after replies and Wait for a reply will be available when conversation is connected.") }
        item { HorizontalDivider(); SettingsHeading("Assistant and Shortcuts") }
        item { SettingsFootnote("Android assistant integration is not connected in this preview.") }
        item { HorizontalDivider(); SettingsHeading("Newsletters") }
        item { SettingsFootnote("Newsletter address management is not available on Android yet.") }
        item { HorizontalDivider(); SettingsHeading("Privacy & Support") }
        item { SettingsAction("Privacy Policy", Icons.AutoMirrored.Rounded.OpenInNew) { open(Intent(Intent.ACTION_VIEW, "https://audio-reader-production.up.railway.app/privacy".toUri())) } }
        item { SettingsAction("Email Support", Icons.Rounded.Email) { open(Intent(Intent.ACTION_SENDTO, "mailto:hcndashwood@gmail.com".toUri())) } }
        item { ListItem(headlineContent = { Text("AI Data Sharing") }, supportingContent = { Text("Off · Voice requests are not connected") }) }
        item { SettingsFootnote("Article narration and voice previews run on this device. No account or library data is sent to an AI service in this preview.") }
        item { HorizontalDivider(); SettingsHeading("Account") }
        item { SettingsAction("Sign-in Methods", Icons.Rounded.AccountCircle, onAccount) }
        if (linkError != null) item { SettingsFootnote(linkError!!, error = true) }
        item { SettingsFootnote(if (library.live) "Connected account library" else "Android preview · Sample library") }
    }
    if (showingVoices) ModalBottomSheet(onDismissRequest = { showingVoices = false }, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
        Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp), horizontalArrangement = Arrangement.SpaceBetween) {
            Text("Voice", Modifier.padding(vertical = 12.dp).semantics { heading() }, style = MaterialTheme.typography.titleLarge)
            IconButton(onClick = { showingVoices = false }) { Icon(Icons.Rounded.Close, "Close voice chooser") }
        }
        LazyColumn(Modifier.fillMaxWidth().heightIn(max = 440.dp).testTag("voice-list")) {
            item {
                VoiceChoice("Automatic · English", "Choose the best installed English voice", preferences.voiceId == null) { model.selectVoice(null); showingVoices = false }
            }
            if (voices.loading) item { SettingsFootnote("Loading installed voices…") }
            items(voices.voices, key = { it.id }) { voice ->
                VoiceChoice(voice.label, voice.quality, preferences.voiceId == voice.id) { model.selectVoice(voice.id); showingVoices = false }
            }
            if (voices.error != null) item { SettingsFootnote(voices.error!!, error = true) }
        }
    }
}

@Composable
private fun VoiceChoice(title: String, detail: String, selected: Boolean, choose: () -> Unit) {
    ListItem(headlineContent = { Text(title) }, supportingContent = { Text(detail) },
        trailingContent = { RadioButton(selected, onClick = null) },
        modifier = Modifier.clickable(role = Role.RadioButton, onClick = choose).semantics { this.selected = selected })
}

@Composable
private fun SpeedSetting(title: String, current: Float, select: (Float) -> Unit) {
    var expanded by rememberSaveable { mutableStateOf(false) }
    ListItem(headlineContent = { Text(title) }, trailingContent = { Text(speedLabel(current), color = MaterialTheme.colorScheme.primary) },
        modifier = Modifier.clickable(onClickLabel = "Change $title speed") { expanded = true }.testTag("speed-$title"))
    if (expanded) AlertDialog(onDismissRequest = { expanded = false }, title = { Text("$title speed") },
        text = {
            LazyColumn {
                items(playbackRates) { rate ->
                    VoiceChoice(speedLabel(rate), "", current == rate) { select(rate); expanded = false }
                }
            }
        }, confirmButton = { TextButton(onClick = { expanded = false }) { Text("Cancel") } })
}

private fun speedLabel(speed: Float) = "${if (speed % 1f == 0f) speed.toInt().toString() else speed.toString()}×"

@Composable
private fun SettingsAction(title: String, icon: androidx.compose.ui.graphics.vector.ImageVector, action: () -> Unit) {
    ListItem(headlineContent = { Text(title, color = MaterialTheme.colorScheme.primary) }, leadingContent = { Icon(icon, null) }, modifier = Modifier.clickable(onClick = action))
}

@Composable
private fun SettingsHeading(title: String) {
    Text(title, Modifier.padding(horizontal = 16.dp, vertical = 12.dp).semantics { heading() }, style = MaterialTheme.typography.titleSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
}

@Composable
private fun SettingsFootnote(text: String, error: Boolean = false) {
    Text(text, Modifier.padding(horizontal = 16.dp, vertical = 12.dp).semantics { if (error) liveRegion = LiveRegionMode.Polite }, style = MaterialTheme.typography.bodySmall,
        color = if (error) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant)
}
