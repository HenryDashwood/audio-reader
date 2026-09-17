package com.henrydashwood.magpie.ui

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.*
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.repeatOnLifecycle
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.henrydashwood.magpie.MagpieModel
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SubscriptionImportDialog(model: MagpieModel, onFollowing: () -> Unit) {
    val controller = model.subscriptionImport
    val state by controller.state.collectAsStateWithLifecycle()
    val library by model.libraryState.collectAsStateWithLifecycle()
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    var query by remember { mutableStateOf("") }
    var help by remember { mutableStateOf(false) }
    var fileOwner by remember { mutableStateOf<Pair<String?, Int>?>(null) }
    var reading by remember { mutableStateOf(false) }
    DisposableEffect(library.owner, library.revision) { onDispose { controller.invalidate() } }
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri != null) scope.launch {
            reading = true
            try {
                val bytes = withContext(Dispatchers.IO) {
                    context.contentResolver.openInputStream(uri)?.use { it.readBytesBounded(5 * 1024 * 1024) }
                        ?: error("No file")
                }
                val current = model.libraryState.value
                if (fileOwner == (current.owner to current.revision)) controller.preview(bytes)
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (_: Exception) {
                val current = model.libraryState.value
                if (fileOwner == (current.owner to current.revision)) controller.fileError()
            } finally { reading = false }
        }
    }
    if (!state.showing || !library.live) return
    val job = state.job
    LaunchedEffect(state.showing, job?.id, job?.active) {
        lifecycle.repeatOnLifecycle(Lifecycle.State.STARTED) {
            controller.refresh()
            while (controller.state.value.showing && controller.state.value.job?.active == true) {
                delay(if (controller.state.value.error == null) 3000 else 10000)
                controller.refresh()
            }
        }
    }
    fun chooseFile() {
        fileOwner = library.owner to library.revision
        picker.launch(arrayOf("*/*"))
    }
    Dialog(onDismissRequest = controller::close, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Scaffold(topBar = { TopAppBar(title = { Text(job?.title ?: "Import subscriptions") },
            actions = { TextButton(onClick = controller::close) { Text("Done") } }) }) { padding ->
            LazyColumn(Modifier.fillMaxSize().padding(padding).testTag("subscription-import"),
                contentPadding = PaddingValues(20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                if (state.busy || reading) item { LinearProgressIndicator(Modifier.fillMaxWidth().semantics { contentDescription = "Updating import" }) }
                if (state.error != null) item {
                    Text(state.error!!, color = MaterialTheme.colorScheme.error, modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite })
                    TextButton(onClick = controller::refresh, enabled = !state.busy) { Text("Check import status") }
                }
                when {
                    job == null -> {
                        item { Text("Bring the podcasts and publications you follow into Magpie.") }
                        item { Button(onClick = ::chooseFile, enabled = !state.busy && !reading, modifier = Modifier.testTag("choose-opml")) { Text("Choose OPML file") } }
                        item { Text("This imports subscriptions. Reading and listening history aren’t included.") }
                        item { TextButton(onClick = { help = !help }) { Text("How to export from your app") }
                            if (help) Text("In your podcast or RSS reader app, look for Export subscriptions or Export OPML. Save the file, then choose it here.\n\nPocket Casts: Profile → Settings → Import & Export OPML → Save file.\n\nFeedly: Export OPML in the web app.\n\nReadwise Reader: Account → Export Feeds as OPML.") }
                    }
                    job.draft -> {
                        if (job.items.size > 20) item { OutlinedTextField(query, { query = it }, label = { Text("Search subscriptions") }) }
                        item { TextButton(onClick = controller::selectAll, enabled = !state.busy && !state.uncertain) { Text(if (state.selected.isEmpty()) "Select all" else "Deselect all") } }
                        items(job.items.filter { query.isBlank() || it.title.contains(query, ignoreCase = true) }, key = { it.id }) { row ->
                            ListItem(headlineContent = { Text(row.title) }, supportingContent = { Text(row.message ?: if (row.status == "already_following") "Already following" else row.host) },
                                trailingContent = { if (row.status == "ready") Checkbox(row.id in state.selected, { controller.select(row.id, it) },
                                    enabled = !state.busy && !state.uncertain, modifier = Modifier.semantics { contentDescription = "Import ${row.title}" }) })
                        }
                        item { ListItem(headlineContent = { Text("The selected feeds are public") },
                            supportingContent = { Text("Leave out private or paid feed links. This importer adds publicly available feeds only.") },
                            trailingContent = { Switch(state.publicFeeds, controller::publicFeeds, enabled = !state.busy && !state.uncertain,
                                modifier = Modifier.semantics { contentDescription = "The selected feeds are public" }) }) }
                        item { Button(onClick = controller::start, enabled = !state.busy && state.publicFeeds && state.selected.isNotEmpty()) {
                            Text(if (state.uncertain) "Retry import request" else "Import ${state.selected.size} ${if (state.selected.size == 1) "subscription" else "subscriptions"}") } }
                        item { Text("New episodes and articles will appear in Latest. Older items stay available on each subscription’s page.") }
                        if (job.duplicates > 0) item { Text("${job.duplicates} ${if (job.duplicates == 1) "duplicate entry was" else "duplicate entries were"} skipped.") }
                        if (job.folders) item { Text("Folder organisation won’t be imported.") }
                        item { TextButton(onClick = { controller.chooseAnother(); chooseFile() }, enabled = !state.busy && !state.uncertain) { Text("Choose another file") } }
                    }
                    job.active -> {
                        item { Text("${job.finished} of ${job.total} subscriptions checked")
                            LinearProgressIndicator(progress = { job.finished.toFloat() / job.total.coerceAtLeast(1) }, modifier = Modifier.fillMaxWidth()) }
                        item { Text("You can leave this screen. Magpie will keep importing.") }
                        job.items.firstOrNull { it.status == "processing" }?.let { row -> item { Text(row.title) } }
                        job.items.firstOrNull { it.status == "pending" && it.message != null }?.let { row -> item { Text(row.message!!) } }
                        item { Button(onClick = { controller.close(); onFollowing() }) { Text("Go to Following") } }
                        item { TextButton(onClick = controller::stop, enabled = !state.busy) { Text("Stop import") } }
                    }
                    else -> {
                        item { Text(job.title, Modifier.semantics { liveRegion = LiveRegionMode.Polite; heading() }) }
                        item { Text("${job.added} added\n${job.alreadyFollowing} already following\n${job.failed} couldn’t import" +
                            if (job.notImported > 0) "\n${job.notImported} not imported" else "") }
                        item { Button(onClick = { controller.close(); onFollowing() }) { Text("Go to Following") } }
                        if (job.items.any { it.status == "failed" && it.retryable }) item { TextButton(onClick = controller::retry, enabled = !state.busy) { Text("Retry failed") } }
                        items(job.items.filter { it.status == "failed" }, key = { it.id }) { row ->
                            ListItem(headlineContent = { Text(row.title) }, supportingContent = { Text(row.message ?: "Try again later.") }) }
                        item { TextButton(onClick = { controller.chooseAnother(); chooseFile() }, enabled = !state.busy) { Text("Import another file") } }
                    }
                }
            }
        }
    }
}

internal fun java.io.InputStream.readBytesBounded(limit: Int): ByteArray {
    val output = java.io.ByteArrayOutputStream()
    val buffer = ByteArray(8192)
    while (true) {
        val count = read(buffer)
        if (count < 0) break
        require(output.size() + count <= limit) { "File too large" }
        output.write(buffer, 0, count)
    }
    require(output.size() > 0)
    return output.toByteArray()
}
