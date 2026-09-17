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
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.*
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.compose.ui.window.DialogWindowProvider
import androidx.core.view.WindowCompat
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
    var typed by remember { mutableStateOf("") }
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
                permissionError = "Microphone access is off. Allow it in Android app settings to speak, or type your request below."
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
    val history = rememberLazyListState()
    LaunchedEffect(state.turns.size) { if (state.turns.isNotEmpty()) history.animateScrollToItem(state.turns.lastIndex) }
    Dialog(onDismissRequest = { model.voice.close() }, properties = DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false)) {
        val keyboard = LocalSoftwareKeyboardController.current
        val focus = LocalFocusManager.current
        val view = LocalView.current
        val window = (view.parent as? DialogWindowProvider)?.window
        val dark = MaterialTheme.colorScheme.surface.luminance() < .5f
        DisposableEffect(window, dark) {
            val bars = window?.let { WindowCompat.getInsetsController(it, view) }
            val oldStatus = bars?.isAppearanceLightStatusBars
            val oldNavigation = bars?.isAppearanceLightNavigationBars
            bars?.isAppearanceLightStatusBars = !dark
            bars?.isAppearanceLightNavigationBars = !dark
            onDispose {
                oldStatus?.let { bars.isAppearanceLightStatusBars = it }
                oldNavigation?.let { bars.isAppearanceLightNavigationBars = it }
            }
        }
        Surface(Modifier.fillMaxSize()) {
            Column(Modifier.fillMaxSize().systemBarsPadding().imePadding()) {
                TopAppBar(title = { Text("Ask Magpie", Modifier.semantics { heading() }) },
                    actions = { TextButton(onClick = { model.voice.close() }) { Text("Close") } })
                LazyColumn(state = history, modifier = Modifier.weight(1f).fillMaxWidth().testTag("conversation-history"),
                    contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
                    itemsIndexed(state.turns) { _, turn ->
                        Column { Text(if (turn.speaker == "her") "You" else "Magpie", style = MaterialTheme.typography.labelLarge)
                            Text(turn.text) }
                    }
                    if (state.turns.isEmpty()) item {
                        Text("Tap Listen, then ask Magpie to find something, read an article, or control playback. You can also type a request.")
                    }
                    item { Text(when (state.phase) {
                        VoicePhase.Preparing -> "Getting ready…"
                        VoicePhase.Listening -> "Listening…"
                        VoicePhase.Thinking -> "Working on your request…"
                        VoicePhase.Speaking -> "Magpie is speaking…"
                        VoicePhase.Consent -> "Review AI data sharing to continue."
                        VoicePhase.Idle -> "Ready when you are."
                    }, Modifier.semantics { if (state.phase != VoicePhase.Speaking) liveRegion = LiveRegionMode.Polite }) }
                    if (state.heard.isNotBlank()) item { Text("Hearing: ${state.heard}") }
                    if (state.reply.isNotBlank()) item { Text(state.reply) }
                    listOfNotNull(state.error, permissionError, capabilityError).forEach { error -> item {
                        Text(error, color = MaterialTheme.colorScheme.error, modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite })
                    } }
                    if (availability == RecognitionAvailability.Unavailable) item {
                        Text("On-device speech recognition is unavailable. Install an offline recognition service and an English (United Kingdom) language model in Android settings. You can still type a request.")
                    }
                    if (availability in setOf(RecognitionAvailability.DownloadNeeded, RecognitionAvailability.Downloading)) item {
                        Text(if (availability == RecognitionAvailability.Downloading) "The offline recognition language is downloading." else "Download the English (United Kingdom) recognition language to use the microphone offline.")
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
                    item {
                        TextButton(onClick = { scope.launch { checkRecognition() } }) { Text("Check speech availability") }
                        TextButton(onClick = {
                            runCatching { context.startActivity(Intent(Settings.ACTION_SETTINGS)) }
                                .onFailure { capabilityError = "Android settings could not open." }
                        }) { Text("Android speech settings") }
                    }
                    if (state.recoveryRequests.isNotEmpty() && !state.busy) {
                        item {
                            Text("Unfinished requests", Modifier.semantics { heading() })
                            Text("These stay on this device until resolved or dismissed. Signing out removes them.")
                        }
                        items(state.recoveryRequests.size) { index ->
                            val request = state.recoveryRequests[index]
                            Column {
                                Text(request.transcript)
                                TextButton(onClick = { model.voice.retryRequest(request.requestId) },
                                    modifier = Modifier.semantics { contentDescription = "Check request: ${request.transcript}" }) { Text("Check this request") }
                                TextButton(onClick = { dismissRequest = request },
                                    modifier = Modifier.semantics { contentDescription = "Dismiss request: ${request.transcript}" }) { Text("Dismiss request") }
                            }
                        }
                    }
                    item { Text("Recognition and spoken replies run on this device. Library requests share recognised words and relevant library context only with your account’s AI permission.", style = MaterialTheme.typography.bodySmall) }
                }
                Column(Modifier.fillMaxWidth().padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    OutlinedTextField(value = typed, onValueChange = { typed = it.take(2_000) }, label = { Text("Type a request") },
                        modifier = Modifier.fillMaxWidth(), maxLines = 3)
                    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        Button(modifier = Modifier.weight(1f), onClick = {
                            requestListening()
                        }, enabled = !downloading && availability !in setOf(RecognitionAvailability.Unavailable, RecognitionAvailability.DownloadNeeded, RecognitionAvailability.Downloading)) {
                            Text(if (state.phase == VoicePhase.Listening) "Done speaking" else if (state.busy) "Ask again" else "Listen")
                        }
                        OutlinedButton(modifier = Modifier.weight(1f), enabled = typed.isNotBlank(), onClick = { focus.clearFocus(); keyboard?.hide(); model.voice.submit(typed); typed = "" }) { Text("Send") }
                    }
                    if (state.recoverable && !state.busy) TextButton(onClick = model.voice::retry) { Text("Check previous request") }
                }
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
