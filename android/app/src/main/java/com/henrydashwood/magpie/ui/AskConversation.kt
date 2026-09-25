package com.henrydashwood.magpie.ui

import android.Manifest
import android.app.KeyguardManager
import android.content.Intent
import android.content.pm.PackageManager
import android.provider.Settings
import android.view.accessibility.AccessibilityManager
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.Alignment
import androidx.compose.material.icons.rounded.MoreHoriz
import androidx.compose.material.icons.rounded.MicNone
import androidx.compose.material.icons.rounded.Mic
import androidx.compose.material.icons.rounded.KeyboardArrowDown
import androidx.compose.material.icons.rounded.GraphicEq
import androidx.compose.material.icons.automirrored.rounded.VolumeUp
import androidx.compose.material.icons.Icons
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.clickable
import android.net.Uri
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.*
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.henrydashwood.magpie.MagpieModel
import com.henrydashwood.magpie.voice.*
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch
import kotlinx.coroutines.flow.first

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AskConversation(model: MagpieModel) {
    val state by model.voice.state.collectAsStateWithLifecycle()
    if (!state.visible) return
    val context = LocalContext.current
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    val scope = rememberCoroutineScope()
    val haptic = LocalHapticFeedback.current
    val accessibility = context.getSystemService(AccessibilityManager::class.java)
    var dismissRequest by remember { mutableStateOf<VoiceRequest?>(null) }
    LaunchedEffect(state.recoveryRequests) {
        if (state.recoveryRequests.none { it.requestId == dismissRequest?.requestId }) dismissRequest = null
    }
    var permissionError by remember { mutableStateOf<String?>(null) }
    var availability by remember { mutableStateOf<RecognitionAvailability?>(null) }
    var downloading by remember { mutableStateOf(false) }
    var capabilityError by remember { mutableStateOf<String?>(null) }
    // Deliberately not saveable: an old permission result must not reopen the mic after recreation.
    var permissionRequest by remember { mutableStateOf<Int?>(null) }
    var approvedPermission by remember { mutableStateOf<Int?>(null) }
    suspend fun checkRecognition() {
        try { availability = model.speechInput.availability(); capabilityError = null }
        catch (cancelled: CancellationException) { throw cancelled }
        catch (_: Exception) { availability = RecognitionAvailability.Unknown; capabilityError = "The speech service could not report its installed languages. You can try Listen or open Android settings." }
    }
    fun listen() {
        permissionError = null
        val accessible = accessibility?.isTouchExplorationEnabled == true
        model.voice.listen(autoFollowUp = !accessible, accessible = accessible)
    }
    val permission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        val request = permissionRequest
        permissionRequest = null
        if (request != null && model.voice.acceptsMicrophoneRequest(request)) {
            if (granted) approvedPermission = request
            else {
                model.voice.microphoneDenied(accessibility?.isTouchExplorationEnabled == true)
                permissionError = "Microphone access is off. Allow it in Android settings to speak to Magpie."
            }
        }
    }
    fun requestListening() {
        if (context.checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) listen()
        else {
            permissionRequest = model.voice.microphoneRequestVersion
            permission.launch(Manifest.permission.RECORD_AUDIO)
        }
    }
    LaunchedEffect(approvedPermission) {
        approvedPermission?.let { request ->
            lifecycle.currentStateFlow.first { it == Lifecycle.State.RESUMED }
            approvedPermission = null
            if (model.voice.acceptsMicrophoneRequest(request) && context.getSystemService(KeyguardManager::class.java)?.isKeyguardLocked != true) listen()
        }
    }
    LaunchedEffect(state.launchListening) {
        state.launchListening?.let { launch ->
            lifecycle.currentStateFlow.first { it == Lifecycle.State.RESUMED }
            if (model.voice.consumeLaunchListening(launch) && accessibility?.isTouchExplorationEnabled != true &&
                context.getSystemService(KeyguardManager::class.java)?.isKeyguardLocked != true) requestListening()
        }
    }
    DisposableEffect(lifecycle) {
        val observer = LifecycleEventObserver { _, event -> if (event == Lifecycle.Event.ON_STOP) model.voice.background() }
        lifecycle.addObserver(observer)
        onDispose { lifecycle.removeObserver(observer); model.voice.background() }
    }
    LaunchedEffect(Unit) { checkRecognition() }
    LaunchedEffect(state.phase) { if (state.phase == VoicePhase.Listening) haptic.performHapticFeedback(HapticFeedbackType.LongPress) }
    val touchExploration = accessibility?.isTouchExplorationEnabled == true
    val microphoneUsable = !downloading && availability !in setOf(RecognitionAvailability.Unavailable,
        RecognitionAvailability.DownloadNeeded, RecognitionAvailability.Downloading)
    val caption = when (state.phase) {
        VoicePhase.Preparing -> "Getting ready…"
        VoicePhase.Listening -> "Listening…"
        VoicePhase.Thinking -> "Thinking…"
        VoicePhase.Speaking -> state.reply.ifBlank { "Magpie is speaking…" }
        VoicePhase.Consent -> "Review AI data sharing to continue."
        // TalkBack takes over the tap; telling her to tap anywhere would describe the wrong gesture.
        VoicePhase.Idle -> state.reply.ifBlank {
            if (touchExploration) "Double tap to say what you would like" else "Tap anywhere and say what you would like"
        }
    }
    val sheet = rememberModalBottomSheetState()
    // Matches the iOS voice sheet: half height, one large target, and only what the moment needs.
    ModalBottomSheet(onDismissRequest = { model.voice.close() }, sheetState = sheet, dragHandle = null) {
        Box(Modifier.fillMaxWidth().fillMaxHeight().testTag("ask-sheet").semantics { isTraversalGroup = true }) {
            Column(Modifier.fillMaxSize().padding(top = 40.dp).verticalScroll(rememberScrollState()).testTag("ask-content"),
                horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(24.dp)) {
                // One control for the whole area, so she can tap without aiming and TalkBack can find it.
                Column(Modifier.fillMaxWidth().heightIn(min = 240.dp).testTag("ask-microphone")
                    .clickable(enabled = microphoneUsable, role = Role.Button,
                        onClickLabel = if (state.phase == VoicePhase.Listening) "finish speaking" else "speak") { requestListening() }
                    .semantics(mergeDescendants = true) {
                        contentDescription = "Speak to Magpie"
                        stateDescription = caption
                        if (state.phase != VoicePhase.Speaking) liveRegion = LiveRegionMode.Polite
                    }
                    .padding(horizontal = 24.dp, vertical = 16.dp),
                    horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(24.dp)) {
                    Surface(shape = CircleShape, color = MaterialTheme.colorScheme.primary, modifier = Modifier.size(112.dp)) {
                        Box(contentAlignment = Alignment.Center) {
                            Icon(when (state.phase) {
                                VoicePhase.Preparing -> Icons.Rounded.MicNone
                                VoicePhase.Listening -> Icons.Rounded.GraphicEq
                                VoicePhase.Thinking, VoicePhase.Consent -> Icons.Rounded.MoreHoriz
                                VoicePhase.Speaking -> Icons.AutoMirrored.Rounded.VolumeUp
                                VoicePhase.Idle -> Icons.Rounded.Mic
                            }, null, Modifier.size(56.dp), tint = MaterialTheme.colorScheme.onPrimary)
                        }
                    }
                    Text(caption, style = MaterialTheme.typography.titleLarge, textAlign = TextAlign.Center)
                }
                if (state.turns.isNotEmpty() || state.heard.isNotBlank()) Transcript(state.turns, state.heard)
                if (!state.busy || state.phase == VoicePhase.Listening) state.clarification?.choices?.forEach { choice ->
                    OutlinedButton(onClick = { model.voice.choose(choice) }, modifier = Modifier.padding(horizontal = 24.dp)) { Text(choice.label) }
                }
                listOfNotNull(state.error, permissionError, capabilityError).forEach { error ->
                    Text(error, color = MaterialTheme.colorScheme.error, textAlign = TextAlign.Center,
                        modifier = Modifier.padding(horizontal = 24.dp).semantics { liveRegion = LiveRegionMode.Polite })
                }
                // Only when listening has been refused: otherwise the trip to settings is a hunt.
                if (permissionError != null) Button(onClick = {
                    runCatching { context.startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                        Uri.fromParts("package", context.packageName, null))) }
                        .onFailure { capabilityError = "Android settings could not open." }
                }) { Text("Open settings") }
                if (availability == RecognitionAvailability.Unavailable) {
                    Text("On-device speech recognition is unavailable. Install an offline recognition service and an English (United Kingdom) language model in Android settings.",
                        textAlign = TextAlign.Center, modifier = Modifier.padding(horizontal = 24.dp))
                    TextButton(onClick = {
                        runCatching { context.startActivity(Intent(Settings.ACTION_SETTINGS)) }
                            .onFailure { capabilityError = "Android settings could not open." }
                    }) { Text("Android speech settings") }
                }
                if (availability in setOf(RecognitionAvailability.DownloadNeeded, RecognitionAvailability.Downloading)) {
                    Text(if (availability == RecognitionAvailability.Downloading) "The offline recognition language is downloading."
                        else "Download the English (United Kingdom) recognition language to use the microphone offline.",
                        textAlign = TextAlign.Center, modifier = Modifier.padding(horizontal = 24.dp))
                    TextButton(enabled = !downloading, onClick = {
                        downloading = true
                        scope.launch {
                            try { model.speechInput.requestModelDownload(); checkRecognition() }
                            catch (cancelled: CancellationException) { throw cancelled }
                            catch (failure: Exception) { capabilityError = failure.message }
                            finally { downloading = false }
                        }
                    }) { Text(if (downloading) "Downloading…" else "Download recognition language") }
                }
                if (state.recoverable && !state.busy) TextButton(onClick = model.voice::retry) { Text("Check previous request") }
                if (state.recoveryRequests.isNotEmpty() && !state.busy) Column(Modifier.fillMaxWidth().padding(horizontal = 24.dp)
                    .testTag("recovery-requests"), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text("Unfinished requests", style = MaterialTheme.typography.titleMedium, modifier = Modifier.semantics { heading() })
                    Text("These stay on this device until resolved or dismissed. Signing out removes them.")
                    state.recoveryRequests.forEach { request ->
                        Column {
                            Text(request.transcript)
                            TextButton(onClick = { model.voice.retryRequest(request.requestId) },
                                modifier = Modifier.semantics { contentDescription = "Check request: ${request.transcript}" }) { Text("Check this request") }
                            TextButton(onClick = { dismissRequest = request },
                                modifier = Modifier.semantics { contentDescription = "Dismiss request: ${request.transcript}" }) { Text("Dismiss request") }
                        }
                    }
                }
                Spacer(Modifier.navigationBarsPadding().height(16.dp))
            }
            // Last in reading order: it is the escape hatch, not the purpose of the sheet.
            IconButton(onClick = { model.voice.close() }, modifier = Modifier.align(Alignment.TopEnd).padding(8.dp)
                .semantics { traversalIndex = 1f }) {
                Icon(Icons.Rounded.KeyboardArrowDown, "Close")
            }
        }
    }
    dismissRequest?.let { request ->
        AlertDialog(onDismissRequest = { dismissRequest = null }, title = { Text("Stop checking this request?") },
            text = { Text("Magpie will cancel any unfinished work. Library changes already made will remain.") },
            confirmButton = { TextButton(onClick = { dismissRequest = null; model.voice.dismissRequest(request.requestId) }) { Text("Dismiss request") } },
            dismissButton = { TextButton(onClick = { dismissRequest = null }) { Text("Keep request") } })
    }
    if (state.phase == VoicePhase.Consent) AIConsentDialog(false, state.error, model.voice::allowAI, model.voice::declineAI)
}

/** Plain named turns, newest at the bottom: what she said, what Magpie heard, and what it answered. */
@Composable
private fun Transcript(turns: List<ConversationTurn>, heard: String) {
    val history = rememberLazyListState()
    val count = turns.size + if (heard.isNotBlank()) 1 else 0
    LaunchedEffect(count) { if (count > 0) history.animateScrollToItem(count - 1) }
    LazyColumn(state = history, modifier = Modifier.fillMaxWidth().heightIn(max = 200.dp).testTag("conversation-history")
        .semantics { contentDescription = "Conversation" }, contentPadding = PaddingValues(horizontal = 24.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp)) {
        itemsIndexed(turns) { _, turn ->
            val name = if (turn.speaker == "her") "You" else "Magpie"
            Column(Modifier.fillMaxWidth().semantics(mergeDescendants = true) { contentDescription = "$name said: ${turn.text}" }) {
                Text(name, style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                Text(turn.text, color = if (turn.speaker == "her") MaterialTheme.colorScheme.onSurface else MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
        // Partial words change constantly; TalkBack reads the final turn once instead.
        if (heard.isNotBlank()) item {
            Column(Modifier.fillMaxWidth().clearAndSetSemantics { }) {
                Text("You", style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                Text(heard)
            }
        }
    }
}
