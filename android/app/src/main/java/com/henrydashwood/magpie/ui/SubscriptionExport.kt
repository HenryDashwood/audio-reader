package com.henrydashwood.magpie.ui

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.*
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.henrydashwood.magpie.MagpieModel
import com.henrydashwood.magpie.auth.AccountFailure
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

@Composable
fun SubscriptionExportDialog(model: MagpieModel, showing: Boolean, onDismiss: () -> Unit) {
    val library by model.libraryState.collectAsStateWithLifecycle()
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val pending by model.pendingSubscriptionExport.collectAsStateWithLifecycle()
    var owner by remember { mutableStateOf<Pair<String?, Int>?>(null) }
    var busy by remember { mutableStateOf(false) }
    var message by remember { mutableStateOf<String?>(null) }
    fun currentOwner() = model.libraryState.value.let { it.owner to it.revision }
    val save = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument("text/x-opml")) { uri ->
        val data = model.pendingSubscriptionExport.value
        val expected = data?.owner
        model.clearSubscriptionExport()
        if (uri != null && data != null && expected == currentOwner()) {
            busy = true
            scope.launch {
                try {
                    withContext(Dispatchers.IO) {
                        check(expected == currentOwner())
                        checkNotNull(context.contentResolver.openOutputStream(uri, "wt")).use {
                            it.write(data.xml.toByteArray(Charsets.UTF_8))
                        }
                    }
                    if (expected == currentOwner()) message = "Subscriptions exported."
                } catch (cancelled: CancellationException) { throw cancelled }
                catch (_: Exception) { if (expected == currentOwner()) message = "The file couldn’t be saved. Please try again." }
                finally { busy = false }
            }
        }
    }
    LaunchedEffect(library.owner, library.revision, showing) {
        if (!showing || !library.live || (owner != null && owner != currentOwner()) || (pending != null && pending?.owner != currentOwner())) {
            model.clearSubscriptionExport(); owner = null; busy = false; message = null
            if (showing) onDismiss()
        }
    }
    if (!showing || !library.live) return
    AlertDialog(onDismissRequest = { if (!busy) { model.clearSubscriptionExport(); onDismiss() } },
        title = { Text("Export subscriptions") },
        text = {
            Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(16.dp)) {
                Text("Save your podcasts and RSS publications as an OPML file to use in another app.")
                Text("The file includes any personal feed links. Email-only subscriptions and reading or listening history aren’t included.")
                if (busy) LinearProgressIndicator(Modifier.fillMaxWidth().semantics { contentDescription = "Preparing export" })
                message?.let { Text(it, Modifier.semantics { liveRegion = LiveRegionMode.Polite }) }
            }
        },
        confirmButton = {
            TextButton(enabled = !busy && pending == null, onClick = {
                val expected = currentOwner()
                owner = expected; busy = true; message = null
                scope.launch {
                    try {
                        model.exportSubscriptions()
                        if (expected == currentOwner()) {
                            save.launch("Magpie-subscriptions.opml")
                        }
                    } catch (cancelled: CancellationException) { throw cancelled }
                    catch (failure: Exception) {
                        if (expected == currentOwner()) message = (failure as? AccountFailure)?.message
                            ?: "Subscriptions couldn’t be exported. Please try again."
                    } finally { busy = false }
                }
            }) { Text("Export OPML file") }
        },
        dismissButton = { TextButton(enabled = !busy, onClick = { model.clearSubscriptionExport(); onDismiss() }) { Text("Done") } })
}
