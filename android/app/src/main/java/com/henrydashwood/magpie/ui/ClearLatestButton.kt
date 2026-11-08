package com.henrydashwood.magpie.ui

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.CheckCircleOutline
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.henrydashwood.magpie.MagpieModel

@Composable
fun ClearLatestButton(model: MagpieModel) {
    val library = model.libraryState.collectAsStateWithLifecycle().value
    val session = "${library.owner}:${library.revision}"
    var confirmingSession by rememberSaveable { mutableStateOf<String?>(null) }
    val clearing by model.clearingLatest.collectAsStateWithLifecycle()
    val error by model.clearLatestError.collectAsStateWithLifecycle()
    IconButton(enabled = !clearing, onClick = { confirmingSession = session }) {
        Icon(Icons.Rounded.CheckCircleOutline, "Clear Latest")
    }
    fun dismissConfirmation() {
        if (confirmingSession == session) confirmingSession = null
    }
    if (confirmingSession == session) AlertDialog(onDismissRequest = ::dismissConfirmation, title = { Text("Clear Latest?") },
        text = { Text("This removes all current items from Latest without marking them as played. New episodes will still appear.") },
        confirmButton = { TextButton(onClick = {
            if (confirmingSession == session) {
                dismissConfirmation()
                model.clearLatest(library.revision)
            }
        }) { Text("Clear Latest", color = MaterialTheme.colorScheme.error) } },
        dismissButton = { TextButton(onClick = ::dismissConfirmation) { Text("Cancel") } })
    if (error != null) AlertDialog(onDismissRequest = model::dismissClearLatestError, title = { Text("Could not clear Latest") },
        text = { Text(error!!) }, confirmButton = { TextButton(onClick = model::dismissClearLatestError) { Text("OK") } })
}
