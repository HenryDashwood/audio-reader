package com.henrydashwood.magpie.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.rounded.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.*
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.henrydashwood.magpie.MagpieModel
import com.henrydashwood.magpie.data.*
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SourceDiscoveryDialog(model: MagpieModel, openItem: (LibraryItem) -> Unit) {
    val controller = model.discovery
    val state by controller.state.collectAsStateWithLifecycle()
    val library by model.libraryState.collectAsStateWithLifecycle()
    val playback by model.player.collectAsStateWithLifecycle()
    if (!state.showing || !library.live) return
    val nested = state.selected != null || state.candidates != null
    Dialog(onDismissRequest = { if (nested) controller.back() else controller.close() },
        properties = DialogProperties(usePlatformDefaultWidth = false)) {
        BackHandler { if (nested) controller.back() else controller.close() }
        Scaffold(topBar = {
            TopAppBar(title = { Text(if (state.selected != null) "Preview" else if (state.candidates != null) "Choose a feed" else "Add sources") },
                navigationIcon = { if (nested) IconButton(enabled = !state.following, onClick = controller::back) { Icon(Icons.AutoMirrored.Rounded.ArrowBack, "Back to source results") } },
                actions = { TextButton(enabled = !state.following, onClick = controller::close) { Text("Done") } })
        }) { padding ->
            Column(Modifier.fillMaxSize().padding(padding)) {
                if (!nested) {
                    OutlinedTextField(state.query, controller::edit, Modifier.fillMaxWidth().padding(horizontal = 16.dp).testTag("source-query"),
                        label = { Text("Podcast, publication, or web address") }, singleLine = true,
                        keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search), keyboardActions = KeyboardActions(onSearch = { controller.submit() }))
                    TextButton(onClick = controller::submit, enabled = state.query.trim().length >= 2 && !state.loading) {
                        Text(if (SourceDiscovery.isAddress(state.query)) "Find feeds" else "Search")
                    }
                }
                if (state.loading || state.following) LinearProgressIndicator(Modifier.fillMaxWidth().semantics { contentDescription = "Loading sources" })
                LazyColumn(Modifier.fillMaxSize().testTag("source-discovery-list"), contentPadding = PaddingValues(bottom = 24.dp)) {
                    if (state.error != null && !state.askingConsent) item {
                        Column(Modifier.padding(16.dp)) {
                            Text(state.error!!, color = MaterialTheme.colorScheme.error, modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite })
                            if (!state.following) TextButton(onClick = controller::retry, enabled = !state.loading) { Text("Try again") }
                        }
                    }
                    val preview = state.preview
                    when {
                        state.selected != null -> if (preview != null) {
                            item {
                                Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                                    Text(preview.feed.title, style = MaterialTheme.typography.headlineSmall, modifier = Modifier.semantics { heading() })
                                    state.selected?.publisher?.let { Text(it) }
                                    Text("${preview.feed.count} ${if (preview.feed.articles) "posts" else "episodes"}")
                                    preview.feed.description?.takeIf { it.isNotBlank() }?.let { Text(it) }
                                    if (preview.subscribed) {
                                        Text("Subscribed", modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite })
                                        if (preview.feed.sourceDetails.size > 1) Text("Unsubscribing stops following all sources in this publication.")
                                        if (preview.feed.forwarded) Text("To stop forwarded emails, remove the forwarding rule in your email account.")
                                        TextButton(onClick = controller::unfollow, enabled = !state.following,
                                            modifier = Modifier.semantics { contentDescription = "Unsubscribe from ${preview.feed.title}" }) { Text("Unsubscribe", color = MaterialTheme.colorScheme.error) }
                                    }
                                    else Button(onClick = controller::follow, enabled = !state.following,
                                        modifier = Modifier.semantics { contentDescription = "Subscribe to ${preview.feed.title}" }) { Text(if (state.following) "Subscribing…" else "Subscribe") }
                                }
                            }
                            if (preview.itemIds.isEmpty()) item { Text("No recent items in this feed.", Modifier.padding(16.dp)) }
                            items(preview.itemIds, key = { "preview:$it" }) { id ->
                                library.items.find { it.id == id }?.let { item ->
                                    DiscoveryEpisodeRow(item, playback.item?.id == id && playback.playing,
                                        { controller.close(); openItem(item) }, { if (playback.item?.id == id && playback.playing) model.pause() else model.play(item) })
                                }
                            }
                        }
                        state.candidates != null -> {
                            items(state.candidates.orEmpty(), key = { "candidate:${it.url}" }) { source -> SourceResultRow(source) { controller.select(source) } }
                        }
                        else -> {
                            val local = if (state.query.isBlank() || SourceDiscovery.isAddress(state.query)) emptyList()
                                else library.feeds.filter { it.title.contains(state.query.trim(), ignoreCase = true) }
                            if (state.query.isBlank()) item { Text("Search for a podcast or publication, or paste a website or feed address.", Modifier.padding(16.dp)) }
                            if (SourceDiscovery.isAddress(state.query)) item { Text("Magpie will find the available feeds. You can preview one before subscribing.", Modifier.padding(16.dp)) }
                            if (local.isNotEmpty()) item { DiscoveryHeading("In your library") }
                            items(local, key = { "local:${it.id}" }) { feed ->
                                SourceResultRow(SourceResult(feed.title, feed.url ?: "", count = feed.count)) { feed.url?.let { controller.select(SourceResult(feed.title, it)) } }
                            }
                            val sources = state.sources.filter { source -> local.none { it.url == source.url } }
                            if (sources.isNotEmpty()) item { DiscoveryHeading("Podcasts") }
                            items(sources, key = { "directory:${it.url}" }) { source -> SourceResultRow(source) { controller.select(source) } }
                            if (state.itemIds.isNotEmpty()) item { DiscoveryHeading("Episodes in your library") }
                            items(state.itemIds, key = { "episode:$it" }) { id -> library.items.find { it.id == id }?.let { item ->
                                DiscoveryEpisodeRow(item, playback.item?.id == id && playback.playing,
                                    { controller.close(); openItem(item) }, { if (playback.item?.id == id && playback.playing) model.pause() else model.play(item) })
                            } }
                            state.web?.let { source ->
                                item { DiscoveryHeading("Found on the web") }
                                item { SourceResultRow(source) { controller.select(source) } }
                            }
                            state.webMessage?.let { message -> item { Text(message, Modifier.padding(16.dp).semantics { liveRegion = LiveRegionMode.Polite }) } }
                            if (state.searched && !state.loading && state.error == null && local.isEmpty() && sources.isEmpty() && state.itemIds.isEmpty() && state.web == null)
                                item { Text("No matches", Modifier.padding(16.dp).semantics { liveRegion = LiveRegionMode.Polite }) }
                            if (state.query.trim().length >= 2 && !SourceDiscovery.isAddress(state.query)) item {
                                TextButton(onClick = controller::searchWeb, enabled = !state.loading) { Text("Search the web for a publication") }
                            }
                        }
                    }
                }
            }
        }
    }
    if (state.askingConsent) AIConsentDialog(state.loading, state.error, controller::allowAI, controller::declineAI)
}

@Composable
private fun DiscoveryHeading(title: String) { Text(title, Modifier.padding(16.dp).semantics { heading() }, style = MaterialTheme.typography.titleMedium) }

@Composable
private fun SourceResultRow(source: SourceResult, open: () -> Unit) {
    ListItem(headlineContent = { Text(source.title) }, supportingContent = {
        Column {
            source.publisher?.let { Text(it) }
            source.format?.let { Text("${it.uppercase()} · ${source.count ?: 0} ${if ((source.audioCount ?: 0) > 0) "episodes" else "posts"}") }
            if (source.format == null) source.count?.let { Text("$it items") }
            if (source.primary) Text("Recommended feed")
            source.recentTitle?.let { Text("Latest: $it", maxLines = 2) }
        }
    }, modifier = Modifier.clickable(onClickLabel = "Preview ${source.title}", onClick = open))
    HorizontalDivider()
}

@Composable
private fun DiscoveryEpisodeRow(item: LibraryItem, playing: Boolean, open: () -> Unit, play: () -> Unit) {
    ListItem(headlineContent = { Text(item.title) }, supportingContent = { Text(item.source) },
        trailingContent = { IconButton(onClick = play) { Icon(if (playing) Icons.Rounded.Pause else Icons.Rounded.PlayArrow, "${if (playing) "Pause" else "Play"} ${item.title}") } },
        modifier = Modifier.clickable(onClickLabel = "Open ${item.title}", onClick = open))
    HorizontalDivider()
}

@Composable
fun AIConsentDialog(busy: Boolean, error: String?, allow: () -> Unit, close: () -> Unit) {
    val uriHandler = LocalUriHandler.current
    AlertDialog(onDismissRequest = { if (!busy) close() }, title = { Text("Use AI for voice and web search?") },
        text = { Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text("Magpie uses OpenAI to find publications and, on supported devices, understand voice requests. This permission applies to your account on all devices.")
            Text("Recognised words or a publication search, plus relevant library details, may be shared. OpenAI does not receive your name, email address or account identifier. Android web search does not record your microphone.")
            Text("OpenAI does not use API data to train its models. It may retain content for up to 30 days for abuse monitoring. Recognised voice requests and their results are kept by Magpie for up to 30 days to fix mistakes.")
            Text("You can withdraw permission in Settings → AI Data Sharing. Reading and podcast directory search work without it.")
            TextButton(onClick = { uriHandler.openUri("https://audio-reader-production.up.railway.app/privacy") }) { Text("Privacy Policy") }
            error?.let { Text(it, color = MaterialTheme.colorScheme.error, modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite }) }
        } }, confirmButton = { TextButton(onClick = allow, enabled = !busy) { Text(if (busy) "Saving…" else "Allow AI data sharing") } },
        dismissButton = { TextButton(onClick = close, enabled = !busy) { Text("Not now") } })
}

@Composable
fun AISharingSettings(model: MagpieModel) {
    val library by model.libraryState.collectAsStateWithLifecycle()
    var allowed by remember(library.revision) { mutableStateOf<Boolean?>(null) }
    var error by remember(library.revision) { mutableStateOf<String?>(null) }
    var busy by remember(library.revision) { mutableStateOf(false) }
    var showing by remember(library.revision) { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    suspend fun load() {
        busy = true
        try { allowed = model.aiConsent(); error = null }
        catch (cancelled: CancellationException) { throw cancelled }
        catch (failure: Exception) { error = AccountLibrary.message(failure) }
        finally { busy = false }
    }
    LaunchedEffect(library.revision) { if (library.live) load() }
    fun save(value: Boolean) { scope.launch {
        busy = true; error = null
        try { allowed = model.setAIConsent(value); showing = false }
        catch (cancelled: CancellationException) { throw cancelled }
        catch (failure: Exception) { error = AccountLibrary.message(failure) }
        finally { busy = false }
    } }
    Column {
        ListItem(headlineContent = { Text("AI Data Sharing") }, supportingContent = { Text(when {
            !library.live -> "Sign in to manage account permission"
            busy -> "Updating…"
            allowed == true -> "Allowed · Voice requests and publication web search"
            allowed == false -> "Off · Publication web search needs permission"
            else -> "Could not load permission"
        }) })
        if (library.live) Column(Modifier.padding(horizontal = 16.dp)) {
            if (allowed != null) TextButton(onClick = { showing = true }, enabled = !busy) { Text("Review AI data sharing") }
            if (allowed == true) TextButton(onClick = { save(false) }, enabled = !busy) { Text("Withdraw permission") }
            if (allowed == null) TextButton(onClick = { scope.launch { load() } }, enabled = !busy) { Text("Try again") }
        }
        error?.let { Text(it, Modifier.padding(16.dp).semantics { liveRegion = LiveRegionMode.Polite }, color = MaterialTheme.colorScheme.error) }
    }
    if (showing) AIConsentDialog(busy, error, { save(true) }, { showing = false })
}
