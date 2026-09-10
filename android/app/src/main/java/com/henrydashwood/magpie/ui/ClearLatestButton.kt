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
    var confirming by rememberSaveable { mutableStateOf(false) }
    val clearing by model.clearingLatest.collectAsStateWithLifecycle()
    val error by model.clearLatestError.collectAsStateWithLifecycle()
    IconButton(enabled = !clearing, onClick = { confirming = true }) {
        Icon(Icons.Rounded.CheckCircleOutline, "Clear Latest")
    }
    if (confirming) AlertDialog(onDismissRequest = { confirming = false }, title = { Text("Clear Latest?") },
        text = { Text("This removes all current items from Latest without marking them as played. New episodes will still appear.") },
        confirmButton = { TextButton(onClick = { confirming = false; model.clearLatest() }) { Text("Clear Latest", color = MaterialTheme.colorScheme.error) } },
        dismissButton = { TextButton(onClick = { confirming = false }) { Text("Cancel") } })
    if (error != null) AlertDialog(onDismissRequest = model::dismissClearLatestError, title = { Text("Could not clear Latest") },
        text = { Text(error!!) }, confirmButton = { TextButton(onClick = model::dismissClearLatestError) { Text("OK") } })
}
