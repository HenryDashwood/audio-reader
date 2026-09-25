package com.henrydashwood.magpie.ui

import android.content.ActivityNotFoundException
import android.content.Intent
import android.provider.Settings
import android.speech.tts.TextToSpeech
import androidx.compose.foundation.clickable
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.automirrored.rounded.OpenInNew
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.*
import androidx.compose.ui.text.font.FontWeight
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
    LazyColumn(Modifier.fillMaxSize().testTag("settings-list"), contentPadding = PaddingValues(bottom = 24.dp)) {
        item {
            SettingsSection("Playback Speed", top = 8.dp, footer = "Magpie remembers separate speeds for podcasts and articles. Article speed also applies to spoken replies and newsletter addresses.") {
                SpeedSetting("Podcasts", preferences.podcastSpeed) { model.setSpeed(ContentKind.Podcast, it) }
                SpeedSetting("Articles", preferences.articleSpeed) { model.setSpeed(ContentKind.Article, it) }
            }
        }
        item {
            SettingsSection("Voice", "Choose from installed offline Google voices. Download more voices in Android’s text-to-speech settings. A voice change applies the next time you start an article.") {
                ListItem(headlineContent = { Text("Voice") }, supportingContent = { Text(if (voices.loading) "Loading installed voices…" else selectedVoice) },
                    trailingContent = { Icon(Icons.Rounded.ChevronRight, null) },
                    modifier = Modifier.clickable(onClickLabel = "Choose voice") { showingVoices = true }.testTag("voice-setting"))
                voices.error?.let { SettingsFootnote(it, error = true) }
                SettingsAction("Download voices", Icons.Rounded.Download) {
                    try { context.startActivity(Intent(TextToSpeech.Engine.ACTION_INSTALL_TTS_DATA).setPackage(SpeechVoices.ENGINE)) }
                    catch (_: ActivityNotFoundException) { open(Intent(Settings.ACTION_SETTINGS)) }
                }
                SettingsAction("Refresh voices", Icons.Rounded.Refresh, model::refreshVoices)
            }
        }
        item {
            SettingsSection("Conversation", "After Magpie answers, wait for the listening sound and speak again. Silence ends listening; say “That’s all” to close the conversation. Starting playback also ends listening. With TalkBack, double-tap the microphone for each turn.") {
                ListItem(headlineContent = { Text("Keep listening after replies") }, supportingContent = { Text("Continue the conversation after Magpie answers.") },
                    trailingContent = { Switch(conversation.keepListening, { model.setConversationPreferences(conversation.copy(keepListening = it)) }, Modifier.semantics { contentDescription = "Keep listening after replies" }) })
                if (conversation.keepListening) ListItem(headlineContent = { Text("Wait for a reply") },
                    trailingContent = { Text("${conversation.followUpSeconds} seconds", color = MaterialTheme.colorScheme.primary, style = MaterialTheme.typography.bodyLarge) },
                    modifier = Modifier.clickable { showingWait = true }.testTag("conversation-wait"))
            }
        }
        item {
            SettingsSection("Assistant and Shortcuts") {
                SettingsAction("Home screen and Quick Settings", Icons.Rounded.AppShortcut, onShortcuts)
            }
        }
        if (library.live) item {
            SettingsSection("Library") {
                SettingsAction("Import subscriptions", Icons.Rounded.FileOpen, model.subscriptionImport::open)
                SettingsAction("Export subscriptions", Icons.Rounded.FileUpload) { showingExport = true }
            }
        }
        item {
            SettingsSection("Newsletters", if (library.live) "Give this address to a newsletter instead of your own email. The first time a sender writes, Magpie asks whether to follow them before anything is read to you." else null) {
                NewsletterAddressSection(model)
            }
        }
        item {
            SettingsSection("Privacy & Support", "Voice requests use OpenAI only after you allow it. Turning it off leaves the rest of Magpie available.") {
                ListItem(headlineContent = { Text("Share app diagnostics") },
                    supportingContent = { Text("Send voice-request outcomes and crash or freeze summaries. Never your words or audio.") },
                    trailingContent = { Switch(diagnostics, model::setDiagnosticsEnabled,
                        Modifier.semantics { contentDescription = "Share app diagnostics" }) })
                SettingsAction("Privacy Policy", Icons.AutoMirrored.Rounded.OpenInNew) { open(Intent(Intent.ACTION_VIEW, "https://audio-reader-production.up.railway.app/privacy".toUri())) }
                SettingsAction("Email Support", Icons.Rounded.Email) { open(Intent(Intent.ACTION_SENDTO, "mailto:hcndashwood@gmail.com".toUri())) }
                AISharingSettings(model)
                linkError?.let { SettingsFootnote(it, error = true) }
            }
        }
        item {
            // As on iOS, signing out and deleting the account live here rather than a level deeper.
            SettingsSection("Account") {
                SettingsAction("Sign-in Methods", Icons.Rounded.AccountCircle, onAccount)
                AccountActions()
            }
        }
    }
    if (showingWait) ChoiceDialog("Wait for a reply", com.henrydashwood.magpie.voice.ConversationPreferences.waitOptions, conversation.followUpSeconds,
        { "$it seconds" }, { model.setConversationPreferences(conversation.copy(followUpSeconds = it)) }) { showingWait = false }
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
    ListItem(headlineContent = { Text(title) }, supportingContent = detail.takeIf { it.isNotBlank() }?.let { { Text(it) } },
        trailingContent = { RadioButton(selected, onClick = null) }, colors = ListItemDefaults.colors(containerColor = Color.Transparent),
        modifier = Modifier.clickable(role = Role.RadioButton, onClick = choose).semantics { this.selected = selected })
}

@Composable
private fun SpeedSetting(title: String, current: Float, select: (Float) -> Unit) {
    var expanded by rememberSaveable { mutableStateOf(false) }
    ListItem(headlineContent = { Text(title) }, trailingContent = { Text(speedLabel(current), color = MaterialTheme.colorScheme.primary, style = MaterialTheme.typography.bodyLarge) },
        modifier = Modifier.clickable(onClickLabel = "Change $title speed") { expanded = true }.testTag("speed-$title"))
    if (expanded) ChoiceDialog("$title speed", playbackRates, current, ::speedLabel, select) { expanded = false }
}

/** Android's single-choice dialog: radio buttons on the left; choosing closes it. */
@Composable
private fun <T> ChoiceDialog(title: String, options: List<T>, selected: T, label: (T) -> String, choose: (T) -> Unit, dismiss: () -> Unit) {
    AlertDialog(onDismissRequest = dismiss, title = { Text(title) },
        text = {
            Column(Modifier.selectableGroup().verticalScroll(rememberScrollState())) {
                options.forEach { option ->
                    Row(Modifier.fillMaxWidth().heightIn(min = 48.dp).clip(RoundedCornerShape(12.dp))
                            .selectable(option == selected, role = Role.RadioButton) { choose(option); dismiss() }
                            .padding(horizontal = 4.dp),
                        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                        RadioButton(option == selected, onClick = null)
                        Text(label(option), style = MaterialTheme.typography.bodyLarge, color = MaterialTheme.colorScheme.onSurface)
                    }
                }
            }
        }, confirmButton = { TextButton(onClick = dismiss) { Text("Cancel") } })
}

internal fun speedLabel(speed: Float) = "${if (speed % 1f == 0f) speed.toInt().toString() else speed.toString()}×"

@Composable
private fun SettingsAction(title: String, icon: androidx.compose.ui.graphics.vector.ImageVector, action: () -> Unit) {
    ListItem(headlineContent = { Text(title, color = MaterialTheme.colorScheme.primary) }, leadingContent = { Icon(icon, null) }, modifier = Modifier.clickable(onClick = action))
}

/**
 * A titled group of rows on a card, with its explanation underneath, like Android's own
 * Settings and iOS's grouped lists. The heading is larger than the rows so the page scans.
 */
@Composable
private fun SettingsSection(title: String, footer: String? = null, top: androidx.compose.ui.unit.Dp = 24.dp, content: @Composable ColumnScope.() -> Unit) {
    Column(Modifier.fillMaxWidth().padding(start = 16.dp, end = 16.dp, top = top)) {
        Text(title, Modifier.padding(start = 16.dp, bottom = 8.dp).semantics { heading() },
            style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold, color = MaterialTheme.colorScheme.primary)
        val colors = MaterialTheme.colorScheme
        Surface(Modifier.fillMaxWidth(), shape = RoundedCornerShape(20.dp), color = colors.surfaceContainer) {
            // Rows draw on the card's colour rather than the page's.
            MaterialTheme(colorScheme = colors.copy(surface = colors.surfaceContainer)) { Column(Modifier.padding(vertical = 4.dp), content = content) }
        }
        footer?.let { Text(it, Modifier.padding(start = 16.dp, end = 16.dp, top = 8.dp), style = MaterialTheme.typography.bodySmall, color = colors.onSurfaceVariant) }
    }
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
