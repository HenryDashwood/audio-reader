package com.henrydashwood.magpie.ui

import android.app.StatusBarManager
import android.content.ComponentName
import android.graphics.drawable.Icon
import android.os.Build
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.Alignment
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.*
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.henrydashwood.magpie.MagpieModel
import com.henrydashwood.magpie.shortcuts.*

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ShortcutsScreen(model: MagpieModel, onBack: () -> Unit) {
    val context = LocalContext.current
    val library by model.libraryState.collectAsStateWithLifecycle()
    val working by model.shortcutWorking.collectAsStateWithLifecycle()
    val notice by model.notice.collectAsStateWithLifecycle()
    var message by remember { mutableStateOf<String?>(null) }
    var selection by remember { mutableStateOf<ShortcutAction?>(null) }
    val canPin = remember { MagpieShortcuts.supportsPin(context) }
    fun pin(request: ShortcutRequest, label: String = request.action.label) {
        message = try {
            if (MagpieShortcuts.pin(context, request, label)) "Confirm with your home screen to add the shortcut."
            else "This home screen cannot add pinned shortcuts. Try holding the Magpie app icon instead."
        } catch (_: Exception) { "The home screen could not add this shortcut. Please try again." }
    }
    fun tile(action: ShortcutAction) {
        if (Build.VERSION.SDK_INT < 33) { message = "Open Quick Settings, tap Edit, then drag the Magpie tile into your active tiles."; return }
        val component = ComponentName(context, if (action == ShortcutAction.Ask) AskMagpieTile::class.java else ContinueListeningTile::class.java)
        try {
            context.getSystemService(StatusBarManager::class.java).requestAddTileService(component, action.label,
                Icon.createWithResource(context, MagpieShortcuts.icon(action)), context.mainExecutor) { result ->
                message = when (result) {
                    StatusBarManager.TILE_ADD_REQUEST_RESULT_TILE_ADDED -> "Tile added to Quick Settings."
                    StatusBarManager.TILE_ADD_REQUEST_RESULT_TILE_ALREADY_ADDED -> "This tile is already in Quick Settings."
                    StatusBarManager.TILE_ADD_REQUEST_RESULT_TILE_NOT_ADDED -> "Tile was not added. You can add it later."
                    else -> "Open Quick Settings and use Edit to add this Magpie tile."
                }
            }
        } catch (_: Exception) { message = "Open Quick Settings and use Edit to add this Magpie tile." }
    }
    Scaffold(topBar = { Surface {
        Row(Modifier.fillMaxWidth().windowInsetsPadding(WindowInsets.statusBars).heightIn(min = 64.dp).padding(end = 16.dp),
            verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Rounded.ArrowBack, "Back") }
            Text("Assistant and Shortcuts", Modifier.weight(1f).padding(vertical = 12.dp).semantics { heading() }, style = MaterialTheme.typography.titleLarge)
        }
    } }) { padding ->
        LazyColumn(Modifier.fillMaxSize().padding(padding).testTag("shortcuts-list"), contentPadding = PaddingValues(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp)) {
            item { Text("Hold the Magpie app icon to find Ask Magpie, Continue listening, Play latest, and Saved articles. You can also add shortcuts to your home screen.") }
            working?.let { item {
                Text("$it…", Modifier.semantics { liveRegion = LiveRegionMode.Polite })
                TextButton(onClick = model::cancelShortcut) { Text("Cancel") }
            } }
            notice?.let { item { Text(it, Modifier.semantics { liveRegion = LiveRegionMode.Polite }, color = MaterialTheme.colorScheme.error) } }
            items(MagpieShortcuts.basics) { action ->
                Column {
                    Text(action.label, style = MaterialTheme.typography.titleMedium)
                    TextButton(onClick = { model.runShortcut(ShortcutRequest(action)) }) { Text("Open ${action.label}") }
                    OutlinedButton(enabled = canPin, onClick = { pin(ShortcutRequest(action)) }) { Text("Add ${action.label} to home screen") }
                }
            }
            item { HorizontalDivider(); Text("Your library", style = MaterialTheme.typography.titleMedium, modifier = Modifier.semantics { heading() }) }
            item { Text("Item and show shortcuts stay linked to the account that created them. Continue listening uses your last item in the current account. Closing the mini player keeps that place.") }
            item { OutlinedButton(enabled = canPin && library.items.isNotEmpty() && !library.loading,
                onClick = { selection = ShortcutAction.ReadItem }) { Text("Add an item shortcut") } }
            item { OutlinedButton(enabled = canPin && library.feeds.isNotEmpty() && !library.loading,
                onClick = { selection = ShortcutAction.PlayFeed }) { Text("Add a show’s latest shortcut") } }
            item { HorizontalDivider(); Text("Quick Settings", style = MaterialTheme.typography.titleMedium, modifier = Modifier.semantics { heading() }) }
            item { Text("Open Ask Magpie or continue listening from the panel above your notifications. Unlock your device first. The Ask shortcut and tile start listening when Magpie opens, with your microphone permission. With TalkBack, tap Listen when you are ready.") }
            item { OutlinedButton(onClick = { tile(ShortcutAction.Ask) }) { Text("Add Ask Magpie tile") } }
            item { OutlinedButton(onClick = { tile(ShortcutAction.Continue) }) { Text("Add Continue listening tile") } }
            item { Text("Your system media controls already support pause, resume, and seeking. Assistant library search and structured automation are still being connected.", style = MaterialTheme.typography.bodySmall) }
            message?.let { item { Text(it, Modifier.semantics { liveRegion = LiveRegionMode.Polite }) } }
        }
    }
    selection?.let { action ->
        val owner = library.owner ?: "sample"
        AlertDialog(onDismissRequest = { selection = null }, title = { Text(if (action == ShortcutAction.PlayFeed) "Choose a show" else "Choose an item") },
            text = { LazyColumn(Modifier.testTag("shortcut-picker")) {
                if (action == ShortcutAction.PlayFeed) items(library.feeds) { feed ->
                    TextButton(onClick = { pin(ShortcutRequest(action, owner, feedId = feed.id), "Latest · ${feed.title}"); selection = null }) { Text(feed.title) }
                } else items(library.items) { item ->
                    Column {
                        Text(item.title, style = MaterialTheme.typography.titleSmall)
                        TextButton(onClick = { pin(ShortcutRequest(ShortcutAction.ReadItem, owner, item.id), "Open · ${item.title}"); selection = null }) { Text("Add reading shortcut") }
                        TextButton(onClick = { pin(ShortcutRequest(ShortcutAction.PlayItem, owner, item.id), "Play · ${item.title}"); selection = null }) { Text("Add listening shortcut") }
                    }
                }
            } }, confirmButton = { TextButton(onClick = { selection = null }) { Text("Cancel") } })
    }
}
