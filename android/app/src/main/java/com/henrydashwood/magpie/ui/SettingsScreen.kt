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
fun SettingsScreen(model: MagpieModel, onShortcuts: () -> Unit = {}, onAccount: () -> Unit) {
    val library by model.libraryState.collectAsStateWithLifecycle()
    val preferences by model.settings.collectAsStateWithLifecycle()
    val conversation by model.conversationSettings.collectAsStateWithLifecycle()
    val diagnostics by model.diagnosticsEnabled.collectAsStateWithLifecycle()
    var showingExport by rememberSaveable { mutableStateOf(false) }
    SubscriptionExportDialog(model, showingExport) { showingExport = false }
    var showingWait by remember { mutableStateOf(false) }
    val voices by model.voices.collectAsStateWithLifecycle()
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    val context = LocalContext.current
    var showingVoices by rememberSaveable { mutableStateOf(false) }
    var linkError by rememberSaveable { mutableStateOf<String?>(null) }
    DisposableEffect(lifecycle, model) {
        val observer = LifecycleEventObserver { _, event ->
            when (event) {
                Lifecycle.Event.ON_RESUME -> model.refreshVoices()
                Lifecycle.Event.ON_PAUSE -> { model.stopVoicePreview(); model.newsletterSpeech.stop() }
                else -> Unit
            }
        }
        lifecycle.addObserver(observer)
        onDispose { lifecycle.removeObserver(observer); model.closeVoiceSettings(); model.newsletterSpeech.stop() }
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
        item { SettingsFootnote("Magpie remembers separate speeds for podcasts and articles. Article speed also applies to spoken replies and newsletter addresses.") }
        item { HorizontalDivider(); SettingsHeading("Voice") }
        item {
            ListItem(headlineContent = { Text("Voice") }, supportingContent = { Text(if (voices.loading) "Loading installed voices…" else selectedVoice) },
                trailingContent = { Icon(Icons.Rounded.ChevronRight, null) },
                modifier = Modifier.clickable(onClickLabel = "Choose voice") { showingVoices = true }.testTag("voice-setting"))
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
        item { ListItem(headlineContent = { Text("Keep listening after replies") }, supportingContent = { Text("Continue the conversation after Magpie answers.") },
            trailingContent = { Switch(conversation.keepListening, { model.setConversationPreferences(conversation.copy(keepListening = it)) }, Modifier.semantics { contentDescription = "Keep listening after replies" }) }) }
        if (conversation.keepListening) item { ListItem(headlineContent = { Text("Wait for a reply") }, trailingContent = { Text("${conversation.followUpSeconds} seconds") },
            modifier = Modifier.clickable { showingWait = true }.testTag("conversation-wait")) }
        item { SettingsFootnote("After Magpie answers, wait for the listening sound and speak again. Silence ends listening; say “That’s all” to close the conversation. Starting playback also ends listening. With TalkBack, double-tap the microphone for each turn.") }
        item { HorizontalDivider(); SettingsHeading("Assistant and Shortcuts") }
        item { SettingsAction("Home screen and Quick Settings", Icons.Rounded.AppShortcut, onShortcuts) }
        if (library.live) {
            item { HorizontalDivider(); SettingsHeading("Library") }
            item { SettingsAction("Import subscriptions", Icons.Rounded.FileOpen, model.subscriptionImport::open) }
            item { SettingsAction("Export subscriptions", Icons.Rounded.FileUpload) { showingExport = true } }
        }
        item { HorizontalDivider(); SettingsHeading("Newsletters") }
        item { NewsletterAddressSection(model) }
        item { HorizontalDivider(); SettingsHeading("Privacy & Support") }
        item { ListItem(headlineContent = { Text("Share app diagnostics") },
            supportingContent = { Text("Send voice-request outcomes and crash or freeze summaries. Never your words or audio.") },
            trailingContent = { Switch(diagnostics, model::setDiagnosticsEnabled,
                Modifier.semantics { contentDescription = "Share app diagnostics" }) }) }
        item { SettingsAction("Privacy Policy", Icons.AutoMirrored.Rounded.OpenInNew) { open(Intent(Intent.ACTION_VIEW, "https://audio-reader-production.up.railway.app/privacy".toUri())) } }
        item { SettingsAction("Email Support", Icons.Rounded.Email) { open(Intent(Intent.ACTION_SENDTO, "mailto:hcndashwood@gmail.com".toUri())) } }
        item { AISharingSettings(model) }
        item { SettingsFootnote("Voice requests use OpenAI only after you allow it. Turning it off leaves the rest of Magpie available.") }
        if (linkError != null) item { SettingsFootnote(linkError!!, error = true) }
        item { HorizontalDivider(); SettingsHeading("Account") }
        item { SettingsAction("Sign-in Methods", Icons.Rounded.AccountCircle, onAccount) }
        // As on iOS, signing out and deleting the account live here rather than a level deeper.
        item { AccountActions() }
    }
    if (showingWait) AlertDialog(onDismissRequest = { showingWait = false }, title = { Text("Wait for a reply") },
        text = { LazyColumn { items(com.henrydashwood.magpie.voice.ConversationPreferences.waitOptions) { seconds ->
            VoiceChoice("$seconds seconds", "", conversation.followUpSeconds == seconds) {
                model.setConversationPreferences(conversation.copy(followUpSeconds = seconds)); showingWait = false
            }
        } } }, confirmButton = { TextButton(onClick = { showingWait = false }) { Text("Close") } })
    if (showingVoices) ModalBottomSheet(onDismissRequest = { showingVoices = false }, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
        Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp), horizontalArrangement = Arrangement.SpaceBetween) {
            Text("Voice", Modifier.padding(vertical = 12.dp).semantics { heading() }, style = MaterialTheme.typography.titleLarge)
            IconButton(onClick = { showingVoices = false }) { Icon(Icons.Rounded.Close, "Close voice chooser") }
        }
        LazyColumn(Modifier.fillMaxWidth().heightIn(max = 440.dp).testTag("voice-list")) {
            item {
                VoiceChoice("Automatic · English", "Choose the best installed English voice", preferences.voiceId == null) { model.selectVoice(null); model.previewVoice(); showingVoices = false }
            }
            if (voices.loading) item { SettingsFootnote("Loading installed voices…") }
            items(voices.voices, key = { it.id }) { voice ->
                VoiceChoice(voice.label, voice.quality, preferences.voiceId == voice.id) { model.selectVoice(voice.id); model.previewVoice(); showingVoices = false }
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

internal fun speedLabel(speed: Float) = "${if (speed % 1f == 0f) speed.toInt().toString() else speed.toString()}×"

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

@Composable
private fun AccountActions(model: com.henrydashwood.magpie.auth.AccountModel = androidx.lifecycle.viewmodel.compose.viewModel()) {
    val state by model.state.collectAsStateWithLifecycle()
    AccountActions(state, model::signOut, model::delete)
}

@Composable
internal fun AccountActions(state: com.henrydashwood.magpie.auth.AccountState, signOut: () -> Unit, delete: () -> Unit) {
    var confirmingDelete by rememberSaveable { mutableStateOf(false) }
    Column {
        ListItem(headlineContent = { Text("Sign Out", color = MaterialTheme.colorScheme.error) },
            modifier = Modifier.clickable(enabled = !state.busy, onClickLabel = "sign out and return to the sign-in screen") { signOut() })
        ListItem(headlineContent = { Text("Delete Account", color = MaterialTheme.colorScheme.error) },
            modifier = Modifier.clickable(enabled = !state.busy) { confirmingDelete = true })
        if (state.busy) SettingsFootnote("Updating account…")
        state.error?.let { SettingsFootnote(it, error = true) }
    }
    if (confirmingDelete) AlertDialog(onDismissRequest = { confirmingDelete = false },
        title = { Text("Delete your account?") },
        text = { Text("This removes your account, the shows you follow, and your place in every episode. It cannot be undone.") },
        confirmButton = { TextButton(onClick = { confirmingDelete = false; delete() }) { Text("Delete Account", color = MaterialTheme.colorScheme.error) } },
        dismissButton = { TextButton(onClick = { confirmingDelete = false }) { Text("Cancel") } })
}
