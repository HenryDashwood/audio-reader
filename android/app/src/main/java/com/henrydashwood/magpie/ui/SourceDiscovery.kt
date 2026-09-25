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
import androidx.compose.ui.draw.clip
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.saveable.rememberSaveable
import com.henrydashwood.magpie.data.countLabel
import com.henrydashwood.magpie.data.sectionTitle
import androidx.compose.ui.Alignment
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
fun SourceDiscoveryDialog(model: MagpieModel, openItem: (LibraryItem) -> Unit, openSource: (String) -> Unit = {}) {
    var scope by rememberSaveable { mutableIntStateOf(0) } // All, Sources, Episodes — as iOS search scopes
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
            // As on iOS, a preview is titled with the podcast's own name.
            TopAppBar(title = { Text(state.selected?.title ?: if (state.candidates != null) "Choose a feed" else "Add sources", maxLines = 1,
                overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis) },
                navigationIcon = { if (nested) IconButton(enabled = !state.following, onClick = controller::back) { Icon(Icons.AutoMirrored.Rounded.ArrowBack, "Back to source results") } },
                actions = { TextButton(enabled = !state.following, onClick = controller::close) { Text("Done") } })
        }) { padding ->
            Column(Modifier.fillMaxSize().padding(padding)) {
                if (!nested) {
                    // Results arrive as she types, as on iOS; a pasted address gets its own row below.
                    OutlinedTextField(state.query, controller::edit, Modifier.fillMaxWidth().padding(horizontal = 16.dp).testTag("source-query"),
                        label = { Text("Podcasts, publications, episodes, or a web address") }, singleLine = true,
                        keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search), keyboardActions = KeyboardActions(onSearch = {
                            if (!SourceDiscovery.isAddress(state.query)) controller.submit() }))
                    if (!SourceDiscovery.isAddress(state.query)) SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp)) {
                        listOf("All", "Sources", "Episodes").forEachIndexed { index, title ->
                            SegmentedButton(selected = scope == index, onClick = { scope = index }, shape = SegmentedButtonDefaults.itemShape(index, 3)) { Text(title) }
                        }
                    }
                }
                if (state.loading || state.following) LinearProgressIndicator(Modifier.fillMaxWidth().semantics { contentDescription = "Loading sources" })
                LazyColumn(Modifier.fillMaxSize().testTag("source-discovery-list"), contentPadding = PaddingValues(bottom = 24.dp)) {
                    if (state.error != null && !state.askingConsent) item {
                        Column(Modifier.padding(16.dp)) {
                            Text(state.error!!, color = MaterialTheme.colorScheme.error, modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite })
                            if (!state.following) TextButton(onClick = controller::retry, enabled = !state.loading) { Text("Try again") }
                            if (SourceDiscovery.isAddress(state.query) && state.selected == null && !state.loading && !state.following)
                                Button(onClick = controller::signUpByEmail) { Text("Sign up by email") }
                        }
                    }
                    val preview = state.preview
                    when {
                        state.signup != null -> item {
                            val signup = state.signup!!
                            Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                                Text(if (signup.submitted) "Asked for the newsletter" else "Needs signing up by hand",
                                    style = MaterialTheme.typography.headlineSmall, modifier = Modifier.semantics { heading() })
                                Text(signup.spokenResponse, Modifier.semantics { liveRegion = LiveRegionMode.Polite })
                                signup.address?.let { address ->
                                    Text(address)
                                    NewsletterAddressActions(address) { model.libraryState.value.live && model.libraryState.value.revision == library.revision }
                                }
                                TextButton(onClick = controller::submit) { Text("Look for feeds again") }
                            }
                        }
                        state.selected != null -> if (preview != null) {
                            item {
                                Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                                    Row(horizontalArrangement = Arrangement.spacedBy(14.dp), verticalAlignment = Alignment.Top) {
                                        ArtworkOrMonogram(preview.feed.title, preview.feed.imageUrl ?: state.selected?.imageUrl, Modifier.size(88.dp))
                                        Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                                            Text(preview.feed.title, style = MaterialTheme.typography.titleLarge, fontWeight = androidx.compose.ui.text.font.FontWeight.SemiBold, modifier = Modifier.semantics { heading() })
                                            state.selected?.publisher?.let { Text(it, color = MaterialTheme.colorScheme.onSurfaceVariant) }
                                            Text(preview.feed.countLabel(), color = MaterialTheme.colorScheme.onSurfaceVariant)
                                        }
                                    }
                                    preview.feed.description?.takeIf { it.isNotBlank() }?.let { Text(it, color = MaterialTheme.colorScheme.onSurfaceVariant) }
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
                            item { DiscoveryHeading(preview.feed.sectionTitle()) }
                            if (preview.itemIds.isEmpty()) item { Text("No recent items in this feed.", Modifier.padding(16.dp)) }
                            items(preview.itemIds, key = { "preview:$it" }) { id ->
                                library.items.find { it.id == id }?.let { item ->
                                    DiscoveryEpisodeRow(item, playback.item?.id == id && playback.playing,
                                        { controller.close(); openItem(item) }, { if (playback.item?.id == id && playback.playing) model.pause() else model.play(item) })
                                }
                            }
                        }
                        state.candidates != null -> {
                            items(state.candidates.orEmpty(), key = { "candidate:${it.url}" }) { source -> FeedCandidateRow(source) { controller.select(source) } }
                            item { Text("Only the feed you open will be added to Magpie’s catalogue.", Modifier.padding(16.dp),
                                style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant) }
                        }
                        else -> {
                            val shows = scope != 2
                            val episodes = scope != 1
                            val address = SourceDiscovery.isAddress(state.query)
                            val local = if (!shows || state.query.isBlank() || address) emptyList()
                                else library.feeds.filter { it.title.contains(state.query.trim(), ignoreCase = true) }
                            val sources = if (!shows) emptyList() else state.sources.filter { source -> local.none { it.url == source.url || it.title.equals(source.title, ignoreCase = true) } }
                            val episodeIds = if (episodes) state.itemIds else emptyList()
                            val web = state.web.takeIf { shows }
                            val nothing = local.isEmpty() && sources.isEmpty() && episodeIds.isEmpty() && web == null
                            if (state.query.isBlank()) item {
                                Text("Search for a podcast or publication, or paste a website or feed address.", Modifier.padding(16.dp))
                                TextButton(onClick = { controller.close(); model.subscriptionImport.open() }, modifier = Modifier.testTag("import-subscriptions")) { Text("Import subscriptions") }
                            }
                            // A pasted address is a complete result of its own, as on iOS.
                            if (address) item {
                                ListItem(headlineContent = { Text("Open podcast or feed") },
                                    supportingContent = { Text(runCatching { java.net.URI(state.query.trim()).host }.getOrNull() ?: state.query.trim()) },
                                    leadingContent = { Icon(Icons.Rounded.Link, null) },
                                    modifier = Modifier.clickable(enabled = !state.loading, onClick = controller::submit))
                                Text("Magpie will check the address and find its RSS or Atom feed before adding it.", Modifier.padding(16.dp),
                                    style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                            }
                            // iOS order: your library, its episodes, the podcast directory, then the web.
                            if (local.isNotEmpty()) item { DiscoveryHeading("In your library") }
                            items(local, key = { "local:${it.id}" }) { feed ->
                                SourceResultRow(SourceResult(feed.title, feed.url ?: "", count = feed.count, imageUrl = feed.imageUrl)) { controller.close(); openSource(feed.id) }
                            }
                            if (episodeIds.isNotEmpty()) item { DiscoveryHeading("Episodes in your library") }
                            items(episodeIds, key = { "episode:$it" }) { id -> library.items.find { it.id == id }?.let { item ->
                                DiscoveryEpisodeRow(item, playback.item?.id == id && playback.playing,
                                    { controller.close(); openItem(item) }, { if (playback.item?.id == id && playback.playing) model.pause() else model.play(item) })
                            } }
                            if (sources.isNotEmpty()) item { DiscoveryHeading("Podcasts") }
                            items(sources, key = { "directory:${it.url}" }) { source -> SourceResultRow(source) { controller.select(source) } }
                            web?.let { source ->
                                item { DiscoveryHeading("Found on the web") }
                                item { SourceResultRow(source) { controller.select(source) } }
                            }
                            state.webMessage?.let { message -> item { Text(message, Modifier.padding(16.dp).semantics { liveRegion = LiveRegionMode.Polite }) } }
                            if (!address && state.query.trim().length in 1..1) item { Text("Enter at least two letters, or paste a podcast or feed address.", Modifier.padding(16.dp)) }
                            if (!address && state.loading && nothing) item { Text("Searching your library and podcasts…", Modifier.padding(16.dp)) }
                            if (state.searched && !state.loading && state.error == null && nothing && !address) item {
                                Text("No matches", Modifier.padding(horizontal = 16.dp).semantics { heading(); liveRegion = LiveRegionMode.Polite }, style = MaterialTheme.typography.titleMedium)
                                Text("Nothing in your library or the podcast directory matches “${state.query.trim()}”.", Modifier.padding(16.dp))
                            }
                            // Offered only when nothing matched, as on iOS.
                            if (shows && nothing && state.searched && !state.loading && state.query.trim().length >= 2 && !address) item {
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
    ListItem(headlineContent = { Text(source.title) }, leadingContent = { DiscoveryArtwork(source.title, source.imageUrl) }, supportingContent = {
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

/** As on iOS (AIDataSharingConsentView): a short intro, four plain disclosures, and Allow pinned below. */
@Composable
fun AIConsentDialog(busy: Boolean, error: String?, allow: () -> Unit, close: () -> Unit) {
    val uriHandler = LocalUriHandler.current
    androidx.compose.ui.window.Dialog(onDismissRequest = { if (!busy) close() },
        properties = androidx.compose.ui.window.DialogProperties(usePlatformDefaultWidth = false)) {
        Surface(Modifier.fillMaxWidth().padding(16.dp).widthIn(max = 520.dp), shape = RoundedCornerShape(28.dp)) {
            Column {
                Column(Modifier.weight(1f, fill = false).verticalScroll(rememberScrollState()).padding(24.dp),
                    verticalArrangement = Arrangement.spacedBy(14.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                    Text("Use AI for voice and web search?", style = MaterialTheme.typography.headlineSmall,
                        textAlign = androidx.compose.ui.text.style.TextAlign.Center, modifier = Modifier.semantics { heading() })
                    Text("Magpie normally turns speech into text on your phone. It uses OpenAI to understand what you ask it to play, carry out requests and find publications.",
                        color = MaterialTheme.colorScheme.onSurfaceVariant, textAlign = androidx.compose.ui.text.style.TextAlign.Center)
                    Surface(color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = .55f), shape = RoundedCornerShape(16.dp)) {
                        Column(Modifier.padding(horizontal = 12.dp)) {
                            DisclosureRow(Icons.Rounded.ChatBubbleOutline, "What is shared", "Recognised words or a publication search, plus relevant library details, go to OpenAI. Your live microphone audio stays with your phone’s speech recogniser.")
                            HorizontalDivider(Modifier.padding(start = 42.dp))
                            DisclosureRow(Icons.Rounded.Shield, "What is not shared", "Your voice recording is not sent to Magpie or OpenAI and is not stored. OpenAI does not receive your name, email address or account identifier.")
                            HorizontalDivider(Modifier.padding(start = 42.dp))
                            DisclosureRow(Icons.Rounded.AccountBalance, "Provider handling", "OpenAI does not use API data to train its models. It may retain content for up to 30 days for abuse monitoring.")
                            HorizontalDivider(Modifier.padding(start = 42.dp))
                            DisclosureRow(Icons.Rounded.Schedule, "Diagnostic record", "The recognised words and result are kept for up to 30 days to fix mistakes.")
                        }
                    }
                    TextButton(onClick = { uriHandler.openUri("https://audio-reader-production.up.railway.app/privacy") }) { Text("Privacy Policy") }
                    error?.let { Text(it, color = MaterialTheme.colorScheme.error, textAlign = androidx.compose.ui.text.style.TextAlign.Center,
                        modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite; contentDescription = "Could not save your choice. $it" }) }
                }
                HorizontalDivider()
                Column(Modifier.fillMaxWidth().padding(horizontal = 24.dp, vertical = 12.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Button(onClick = allow, enabled = !busy, modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp)
                        .semantics { contentDescription = "Allow AI data sharing" }) {
                        if (busy) CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp) else Text("Allow")
                    }
                    TextButton(onClick = close, enabled = !busy, modifier = Modifier.fillMaxWidth()) { Text("Not Now") }
                }
            }
        }
    }
}

@Composable
private fun DisclosureRow(icon: androidx.compose.ui.graphics.vector.ImageVector, title: String, detail: String) {
    Row(Modifier.fillMaxWidth().padding(vertical = 12.dp).semantics(mergeDescendants = true) { }, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        Icon(icon, null, Modifier.size(24.dp), tint = MaterialTheme.colorScheme.primary)
        Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(title, style = MaterialTheme.typography.titleSmall)
            Text(detail, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
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
    var confirmingOff by remember(library.revision) { mutableStateOf(false) }
    // As on iOS: one action, whichever applies, and turning it off asks first.
    Column {
        when (allowed) {
            true -> ListItem(headlineContent = { Text("Turn Off AI Data Sharing", color = MaterialTheme.colorScheme.error) },
                modifier = Modifier.clickable(enabled = !busy, onClickLabel = "stop sending spoken requests and library details to OpenAI") { confirmingOff = true })
            false -> ListItem(headlineContent = { Text("Review AI Data Sharing", color = MaterialTheme.colorScheme.primary) },
                modifier = Modifier.clickable(enabled = !busy) { showing = true })
            null -> if (library.live && !busy) ListItem(headlineContent = { Text("Could not load AI data sharing") },
                supportingContent = { TextButton(onClick = { scope.launch { load() } }) { Text("Try again") } })
        }
        error?.let { Text(it, Modifier.padding(16.dp).semantics { liveRegion = LiveRegionMode.Polite }, color = MaterialTheme.colorScheme.error) }
    }
    if (confirmingOff) AlertDialog(onDismissRequest = { confirmingOff = false }, title = { Text("Turn off AI data sharing?") },
        text = { Text("Magpie will stop sending spoken requests and episode details to OpenAI. You can turn it on again here later.") },
        confirmButton = { TextButton(onClick = { confirmingOff = false; save(false) }) { Text("Turn Off", color = MaterialTheme.colorScheme.error) } },
        dismissButton = { TextButton(onClick = { confirmingOff = false }) { Text("Cancel") } })
    if (showing) AIConsentDialog(busy, error, { save(true) }, { showing = false })
}

@Composable
private fun DiscoveryArtwork(title: String, url: String?) {
    ArtworkOrMonogram(title, url, Modifier.size(48.dp))
}

/** As on iOS: a type icon, the title with a Recommended mark, format and count, and the latest item. */
@Composable
private fun FeedCandidateRow(source: SourceResult, open: () -> Unit) {
    val audio = (source.audioCount ?: 0) > 0
    val format = when (source.format?.lowercase()) { "atom" -> "Atom"; "json" -> "JSON Feed"; "rss" -> "RSS"; null -> null; else -> source.format.uppercase() }
    val count = source.count ?: 0
    val noun = if (audio) "episode" else "post"
    ListItem(headlineContent = {
        Row(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
            Text(source.title, maxLines = 2, modifier = Modifier.weight(1f, fill = false))
            if (source.primary) Icon(Icons.Rounded.Verified, "Recommended", Modifier.size(18.dp), tint = MaterialTheme.colorScheme.primary)
        }
    }, leadingContent = { Icon(if (audio) Icons.Rounded.GraphicEq else Icons.Rounded.Description, null, tint = MaterialTheme.colorScheme.primary) },
        supportingContent = {
            Column {
                Text(listOfNotNull(format, "$count $noun${if (count == 1) "" else "s"}").joinToString(" · "))
                source.recentTitle?.let { Text("Latest: $it", maxLines = 2, style = MaterialTheme.typography.bodySmall) }
            }
        }, modifier = Modifier.clickable(onClickLabel = "Open ${source.title}", onClick = open))
    HorizontalDivider()
}
