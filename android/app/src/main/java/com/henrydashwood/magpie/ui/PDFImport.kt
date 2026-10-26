package com.henrydashwood.magpie.ui

import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.henrydashwood.magpie.BuildConfig
import com.henrydashwood.magpie.MagpieApplication
import com.henrydashwood.magpie.data.*
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

@Composable
fun PDFImportButton() {
    val app = LocalContext.current.applicationContext as MagpieApplication
    val library by app.library.state.collectAsStateWithLifecycle()
    val token by app.accounts.accessToken.collectAsStateWithLifecycle()
    var enabled by remember(library.owner, token) { mutableStateOf(false) }
    var open by remember(library.owner, token) { mutableStateOf(false) }
    LaunchedEffect(library.owner, token) {
        val credential = token ?: return@LaunchedEffect
        try { enabled = PDFClient(BuildConfig.ACCOUNT_API_URL, credential).capability().enabled }
        catch (_: Exception) { }
        while (true) {
            delay(5_000)
            if (app.library.state.value.items.any { it.documentStatus in setOf("queued", "submitting", "processing") }) app.library.refresh()
        }
    }
    if (enabled) TextButton(onClick = { open = true }) { Text("Import PDF") }
    if (open) PDFImportDialog(onClose = { open = false })
}

@Composable
fun PDFImportDialog(initialUri: Uri? = null, onClose: () -> Unit) {
    val app = LocalContext.current.applicationContext as MagpieApplication
    val library by app.library.state.collectAsStateWithLifecycle()
    val token by app.accounts.accessToken.collectAsStateWithLifecycle()
    val scope = rememberCoroutineScope()
    val owner = library.owner
    val inbox = remember { PDFUploadInbox(app) }
    val client = remember(token) { token?.let { PDFClient(BuildConfig.ACCOUNT_API_URL, it) } }
    var capability by remember(owner, token) { mutableStateOf<PDFCapability?>(null) }
    var error by remember(owner, token) { mutableStateOf<String?>(null) }
    var busy by remember(owner, token) { mutableStateOf(false) }
    var queued by remember(owner, token) { mutableStateOf<List<PendingPDF>>(emptyList()) }
    var selected by remember(owner, token) { mutableStateOf(initialUri) }
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { selected = it }
    fun current() = owner != null && owner == app.library.state.value.owner && token == app.accounts.accessToken.value
    fun upload(item: PendingPDF) {
        scope.launch {
            busy = true
            try {
                check(current()) { "Your account changed. Reopen PDF import." }
                val data = inbox.bytes(item)
                check(current()) { "Your account changed." }
                checkNotNull(client).upload(data, item.filename)
                check(current()) { "Your account changed." }
                inbox.remove(item)
                app.library.refresh()
                onClose()
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (failure: Exception) { if (current()) error = failure.message }
            finally { if (current()) { busy = false; queued = inbox.pending(checkNotNull(owner)) } }
        }
    }
    LaunchedEffect(owner, token) {
        try {
            capability = client?.capability()
            queued = owner?.let { inbox.pending(it) }.orEmpty()
        } catch (cancelled: CancellationException) { throw cancelled }
        catch (failure: Exception) { error = failure.message }
    }
    AlertDialog(onDismissRequest = onClose,
        title = { Text("Import PDF") },
        text = { Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text("Import a PDF from Files, or share a PDF link from your browser to Magpie.")
            Text("Datalab receives the PDF or its source link to prepare readable text and images. Imported PDFs stay private to your Magpie account.")
            Text("Up to 25 MiB and 200 pages. Preparation continues after the server accepts the PDF.")
            if (client == null) Text("Open Magpie and sign in first.")
            else if (capability?.enabled == false) Text("PDF importing is not enabled for this account.")
            else if (capability?.enabled == true) {
                if (capability?.consented != true) TextButton(onClick = {
                    scope.launch {
                        busy = true
                        try { val result = client.consent(true); if (current()) capability = result }
                        catch (failure: Exception) { if (current()) error = failure.message }
                        finally { if (current()) busy = false }
                    }
                }, enabled = !busy) { Text("Allow Datalab to process PDFs") }
                else {
                    TextButton(onClick = { picker.launch(arrayOf("application/pdf")) }, enabled = !busy) { Text("Choose PDF") }
                    if (selected != null) TextButton(onClick = {
                        scope.launch {
                            busy = true
                            try {
                                check(current()) { "Your account changed." }
                                val item = inbox.add(checkNotNull(selected), checkNotNull(owner))
                                check(current()) { "Your account changed." }
                                selected = null
                                queued = inbox.pending(owner)
                                upload(item)
                            } catch (failure: Exception) { if (current()) { error = failure.message; busy = false } }
                        }
                    }, enabled = !busy) { Text("Save selected PDF") }
                    TextButton(onClick = { scope.launch {
                        try { val result = client.consent(false); if (current()) capability = result }
                        catch (failure: Exception) { if (current()) error = failure.message }
                    } }, enabled = !busy) { Text("Stop allowing PDF processing") }
                }
                queued.forEach { item ->
                    Text(item.filename)
                    TextButton(onClick = { upload(item) }, enabled = !busy && capability?.consented == true) { Text("Retry upload") }
                    TextButton(onClick = { scope.launch { inbox.remove(item); if (current()) queued = inbox.pending(checkNotNull(owner)) } }, enabled = !busy) { Text("Remove local PDF") }
                }
            }
            if (busy) LinearProgressIndicator(Modifier.fillMaxWidth())
            error?.let { Text(it, color = MaterialTheme.colorScheme.error, modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite }) }
        } },
        confirmButton = { TextButton(onClick = onClose) { Text("Done") } })
}

@Composable
fun DeletePDFButton(item: LibraryItem) {
    val id = item.documentId ?: return
    val app = LocalContext.current.applicationContext as MagpieApplication
    val scope = rememberCoroutineScope()
    var confirming by remember(id) { mutableStateOf(false) }
    var error by remember(id) { mutableStateOf<String?>(null) }
    var busy by remember(id) { mutableStateOf(false) }
    TextButton(onClick = { confirming = true }, enabled = !busy) { Text("Delete PDF") }
    error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
    if (confirming) AlertDialog(onDismissRequest = { confirming = false },
        title = { Text("Delete PDF?") }, text = { Text("Delete ${item.title}, its prepared text and any stored original from your account.") },
        confirmButton = { TextButton(enabled = !busy, onClick = {
            val token = app.accounts.accessToken.value
            val owner = app.library.state.value.owner
            scope.launch {
                busy = true
                try {
                    checkNotNull(token) { "Please sign in again." }
                    PDFClient(BuildConfig.ACCOUNT_API_URL, token).delete(id)
                    if (owner == app.library.state.value.owner && token == app.accounts.accessToken.value) app.library.refresh()
                    confirming = false
                } catch (cancelled: CancellationException) { throw cancelled }
                catch (failure: Exception) { error = failure.message }
                finally { busy = false }
            }
        }) { Text("Delete PDF") } },
        dismissButton = { TextButton(onClick = { confirming = false }) { Text("Cancel") } })
}
