package com.henrydashwood.magpie.ui

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Mic
import androidx.compose.material3.*
import androidx.compose.runtime.*

/** One consistent conversation entry point across the library and reader. */
@Composable
fun AskMagpieButton(onAsk: () -> Unit) {
    IconButton(onClick = onAsk) { Icon(Icons.Rounded.Mic, "Ask Magpie") }
}
