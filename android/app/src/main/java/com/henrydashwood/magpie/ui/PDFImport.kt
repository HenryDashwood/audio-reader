package com.henrydashwood.magpie.ui

import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
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
import kotlinx.coroutines.cancel
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
        try { enabled = PDFClient(BuildConfig.ACCOUNT_API_URL, credential).capability().let { it.enabled || it.subscriptionAvailable } }
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
    val token = app.accounts.accessToken.collectAsStateWithLifecycle().value
    val owner = library.owner?.takeIf { app.library.ownsSession(it, token) }
    val client = remember(token) { token?.let { PDFClient(BuildConfig.ACCOUNT_API_URL, it) } }
    AccountPDFImportDialog(initialUri, owner, client, current = {
        app.library.ownsSession(owner, token) && token == app.accounts.accessToken.value
    }, onClose = onClose)
}

@Composable
internal fun AccountPDFImportDialog(initialUri: Uri?, owner: String?, client: PDFClient?, current: () -> Boolean, onClose: () -> Unit) {
    // A new account may choose its own file. Only the first account can use the incoming attachment.
    var attachmentOwner by rememberSaveable { mutableStateOf<String?>(null) }
    val selectable = initialUri?.takeIf { owner != null && client != null && (attachmentOwner == null || attachmentOwner == owner) }
    if (selectable != null && attachmentOwner == null) SideEffect { attachmentOwner = owner }
    key(owner, client) {
        PDFUploadDialog(selectable, owner, client, current, onClose)
    }
}

@Composable
internal fun PDFUploadDialog(initialUri: Uri?, owner: String?, client: PDFClient?, current: () -> Boolean, onClose: () -> Unit) {
    val app = LocalContext.current.applicationContext as MagpieApplication
    val scope = rememberCoroutineScope()
    val inbox = remember { PDFUploadInbox(app) }
    var showingPlus by remember { mutableStateOf(false) }
    var capability by remember { mutableStateOf<PDFCapability?>(null) }
    var accessCheck by remember { mutableIntStateOf(0) }
    var accessError by remember { mutableStateOf<String?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    var busy by remember { mutableStateOf(false) }
    var queued by remember { mutableStateOf<List<PendingPDF>>(emptyList()) }
    var selected by remember { mutableStateOf(initialUri) }
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { selected = it }
    if (showingPlus) PlusDialog {
        showingPlus = false
        accessCheck++
    }
    fun close() {
        scope.cancel()
        onClose()
    }
    fun upload(prepare: suspend () -> PendingPDF) {
        if (busy || !current()) return
        busy = true
        error = null
        scope.launch {
            try {
                val item = prepare()
                check(current()) { "Your account changed." }
                app.pdfUploads.send(item, inbox, checkNotNull(client)) { current() }
                if (current()) {
                    app.library.refresh()
                    if (current()) close()
                }
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (failure: Exception) {
                if (current()) {
                    queued = inbox.pending(checkNotNull(owner))
                    error = failure.message
                }
            } finally { busy = false }
        }
    }
    LaunchedEffect(owner, client, accessCheck) {
        val attempt = accessCheck
        accessError = null
        try {
            val refreshed = client?.capability()
            val pending = owner?.let { inbox.pending(it) }.orEmpty()
            if (current() && attempt == accessCheck) {
                capability = refreshed
                queued = pending
            }
        } catch (cancelled: CancellationException) { throw cancelled }
        catch (failure: Exception) {
            if (current() && attempt == accessCheck) accessError = failure.message ?: "PDF access could not be checked."
        }
    }
    AlertDialog(onDismissRequest = ::close,
        title = { Text("Import PDF") },
        text = { Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text("Import a PDF from Files, or share a PDF link from your browser to Magpie.")
            Text("Datalab receives the PDF or its source link to prepare readable text and images. Imported PDFs stay private to your Magpie account.")
            Text("Up to 25 MiB and 200 pages. Preparation continues after the server accepts the PDF.")
            if (client == null) Text("Open Magpie and sign in first.")
            else if (capability?.enabled == false) {
                if (capability?.subscriptionAvailable == true) TextButton(onClick = { showingPlus = true }) { Text("Get Magpie Plus") }
                else Text("PDF importing is not available yet.")
            }
            else if (capability?.enabled == true) {
                TextButton(onClick = { picker.launch(arrayOf("application/pdf")) }, enabled = !busy) { Text("Choose PDF") }
                if (selected != null) TextButton(onClick = {
                    upload {
                        val item = inbox.add(checkNotNull(selected), checkNotNull(owner))
                        selected = null
                        item
                    }
                }, enabled = !busy) { Text("Save selected PDF") }
                queued.forEach { item ->
                    Text(item.filename)
                    TextButton(onClick = { upload { item } }, enabled = !busy) { Text("Retry upload") }
                    TextButton(onClick = {
                        scope.launch {
                            if (!current()) return@launch
                            inbox.remove(item)
                            if (current()) queued = inbox.pending(checkNotNull(owner))
                        }
                    }, enabled = !busy) { Text("Remove local PDF") }
                }
            }
            if (accessError != null) TextButton(onClick = { if (current()) accessCheck++ }) { Text("Check access") }
            if (busy) LinearProgressIndicator(Modifier.fillMaxWidth())
            (error ?: accessError)?.let { Text(it, color = MaterialTheme.colorScheme.error, modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite }) }
        } },
        confirmButton = { TextButton(onClick = ::close) { Text("Done") } })
}

@Composable
fun DeletePDFButton(item: LibraryItem) {
    val id = item.documentId ?: return
    val app = LocalContext.current.applicationContext as MagpieApplication
    val token by app.accounts.accessToken.collectAsStateWithLifecycle()
    val library by app.library.state.collectAsStateWithLifecycle()
    val owner = library.owner
    key(id, owner, token) {
        val credential = token
        PDFDeletion(item.title) {
            checkNotNull(credential) { "Please sign in again." }
            check(app.library.ownsSession(owner, credential) && credential == app.accounts.accessToken.value) { "Your account changed." }
            PDFClient(BuildConfig.ACCOUNT_API_URL, credential).delete(id)
            if (app.library.ownsSession(owner, credential) && credential == app.accounts.accessToken.value) app.library.refresh()
        }
    }
}

@Composable
internal fun PDFDeletion(title: String, delete: suspend () -> Unit) {
    val scope = rememberCoroutineScope()
    var review by remember { mutableStateOf<java.util.UUID?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    var busy by remember { mutableStateOf(false) }
    TextButton(onClick = { error = null; review = java.util.UUID.randomUUID() }, enabled = !busy) { Text("Delete PDF") }
    val presented = review ?: return
    fun cancel() {
        if (!busy && review == presented) review = null
    }
    AlertDialog(onDismissRequest = ::cancel,
        title = { Text("Delete PDF?") }, text = {
            Column {
                Text("Delete $title, its prepared text and any stored original from your account.")
                error?.let { Text(it, color = MaterialTheme.colorScheme.error, modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite }) }
            }
        },
        confirmButton = { TextButton(enabled = !busy, onClick = {
            if (busy || review != presented) return@TextButton
            busy = true
            error = null
            scope.launch {
                try {
                    delete()
                    review = null
                } catch (cancelled: CancellationException) { throw cancelled }
                catch (failure: Exception) { error = failure.message }
                finally { busy = false }
            }
        }) { Text("Delete PDF") } },
        dismissButton = { TextButton(enabled = !busy, onClick = ::cancel) { Text("Cancel") } })
}
