package com.henrydashwood.magpie.ui

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Mic
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable

/** One consistent conversation entry point across the library and reader. */
@Composable
fun AskMagpieButton() {
    var asking by rememberSaveable { mutableStateOf(false) }
    IconButton(onClick = { asking = true }) { Icon(Icons.Rounded.Mic, "Ask Magpie") }
    if (asking) AlertDialog(onDismissRequest = { asking = false }, title = { Text("Ask Magpie") },
        text = { Text("Voice conversations are not connected in this Android preview. No microphone audio is being recorded.") },
        confirmButton = { TextButton(onClick = { asking = false }) { Text("Close") } })
}
