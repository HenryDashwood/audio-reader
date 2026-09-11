package com.henrydashwood.magpie.ui

import androidx.compose.foundation.layout.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Bedtime
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.unit.dp
import com.henrydashwood.magpie.playback.SleepTimer
import com.henrydashwood.magpie.playback.SleepTimerState

@Composable
fun SleepTimerButton(timer: SleepTimerState, enabled: Boolean, start: (Int) -> Unit, cancel: () -> Unit) {
    var expanded by remember { mutableStateOf(false) }
    val haptic = LocalHapticFeedback.current
    Box {
        OutlinedButton(onClick = { expanded = true }, enabled = enabled,
            colors = ButtonDefaults.outlinedButtonColors(containerColor = if (timer.running) MaterialTheme.colorScheme.primaryContainer else MaterialTheme.colorScheme.surface),
            modifier = Modifier.heightIn(min = 48.dp).semantics {
                contentDescription = "Sleep timer"
                stateDescription = timer.remainingMinutes?.let { "Stopping in $it ${if (it == 1) "minute" else "minutes"}" } ?: "Off"
            }) {
            Icon(Icons.Rounded.Bedtime, null)
            Spacer(Modifier.width(8.dp))
            Text(timer.remainingMinutes?.let { "$it min" } ?: "Sleep")
        }
        DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            SleepTimer.options.forEach { minutes ->
                DropdownMenuItem(text = { Text("$minutes minutes") }, onClick = {
                    start(minutes)
                    expanded = false
                    haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                })
            }
            if (timer.running) {
                HorizontalDivider()
                DropdownMenuItem(text = { Text("Turn off sleep timer") }, onClick = {
                    cancel()
                    expanded = false
                    haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                })
            }
        }
    }
}
