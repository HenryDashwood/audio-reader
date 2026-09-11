package com.henrydashwood.magpie.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.automirrored.rounded.LibraryBooks
import androidx.compose.material.icons.rounded.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.*
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.henrydashwood.magpie.MagpieModel
import com.henrydashwood.magpie.PlayerState
import com.henrydashwood.magpie.data.playbackRates
import com.henrydashwood.magpie.data.ContentKind
import com.henrydashwood.magpie.data.LibraryItem
import com.henrydashwood.magpie.playback.Preparation
import com.henrydashwood.magpie.playback.SleepTimerState

private enum class Destination(val label: String, val icon: ImageVector) {
    Following("Following", Icons.AutoMirrored.Rounded.LibraryBooks),
    Latest("Latest", Icons.Rounded.Schedule),
    Saved("Saved", Icons.Rounded.BookmarkBorder),
    Settings("Settings", Icons.Rounded.Settings),
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MagpieApp(model: MagpieModel, appleReturn: Int = 0) {
    var showingAccount by rememberSaveable { mutableStateOf(false) }
    val saved by model.saved.collectAsStateWithLifecycle()
    val finished by model.finished.collectAsStateWithLifecycle()
    val dismissedFromLatest by model.dismissedFromLatest.collectAsStateWithLifecycle()
    val latestItems = model.library.filter { it.id !in dismissedFromLatest }
    val pendingSources by model.pendingSources.collectAsStateWithLifecycle()
    val pendingLinks by model.pendingLinks.collectAsStateWithLifecycle()
    var savedListVersion by rememberSaveable { mutableIntStateOf(0) }
    val playback by model.player.collectAsStateWithLifecycle()
    val preparation by model.preparation.collectAsStateWithLifecycle()
    val sleepTimer by model.sleepTimer.collectAsStateWithLifecycle()
    val notice by model.notice.collectAsStateWithLifecycle()
    var destination by rememberSaveable { mutableStateOf(Destination.Following) }
    var selectedItemId by rememberSaveable { mutableStateOf<String?>(null) }
    var selectedSource by rememberSaveable { mutableStateOf<String?>(null) }
    var showingPlayer by rememberSaveable { mutableStateOf(false) }
    var showingSearch by rememberSaveable(destination, selectedSource, selectedItemId) { mutableStateOf(false) }
    var query by rememberSaveable(destination, selectedSource, selectedItemId) { mutableStateOf("") }
    val selectedItem = model.library.find { it.id == selectedItemId }
    val snackbar = remember { SnackbarHostState() }
    val followControl = remember { ArticleFollowControl() }
    LaunchedEffect(appleReturn) { if (appleReturn > 0) showingAccount = true }
    if (showingAccount) {
        BackHandler { showingAccount = false }
        com.henrydashwood.magpie.auth.AccountScreen(onBack = { showingAccount = false })
        return
    }
    LaunchedEffect(playback.item) { if (playback.item == null) showingPlayer = false }
    LaunchedEffect(notice) { notice?.let { snackbar.showSnackbar(it); model.dismissNotice() } }
    LaunchedEffect(preparation.error) { preparation.error?.let { snackbar.showSnackbar(it, duration = SnackbarDuration.Long) } }
    BackHandler(showingSearch || selectedItem != null || selectedSource != null) {
        if (showingSearch) { showingSearch = false; query = ""; return@BackHandler }
        if (selectedItem != null) selectedItemId = null else selectedSource = null
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { if (selectedItem == null && selectedSource == null) Text(destination.label) },
                navigationIcon = {
                    if (selectedItem != null || selectedSource != null) IconButton(onClick = {
                        if (selectedItem != null) selectedItemId = null else selectedSource = null
                    }) { Icon(Icons.AutoMirrored.Rounded.ArrowBack, "Back") }
                },
                actions = {
                    if (selectedItem == null && selectedSource == null && destination == Destination.Following) {
                        AddSourceButton(model) { showingSearch = false; query = "" }
                    }
                    if (selectedItem == null && selectedSource == null && destination == Destination.Saved) {
                        AddLinkButton(model) { savedListVersion++; showingSearch = false; query = "" }
                    }
                    if (selectedItem != null) {
                        val isPlaying = playback.item?.id == selectedItem.id && playback.playing
                        ReaderToolbarActions(selectedItem, isPlaying, showingSearch,
                            { if (isPlaying) model.pause() else model.play(selectedItem) },
                            { showingSearch = !showingSearch; query = "" })
                    } else if (selectedSource != null || destination == Destination.Following || destination == Destination.Saved) {
                        IconButton(onClick = { showingSearch = !showingSearch; query = "" }) {
                            Icon(if (showingSearch) Icons.Rounded.Close else Icons.Rounded.Search,
                                if (showingSearch) "Close search" else "Search")
                        }
                    }
                    if (selectedItem == null && selectedSource == null && destination == Destination.Latest && latestItems.isNotEmpty()) {
                        ClearLatestButton(model)
                    }
                    if (selectedItem == null) AskMagpieButton()
                },
            )
        },
        bottomBar = {
            Column {
                if (preparation.message != null) PreparationBar(preparation, model::cancelPreparation)
                if (playback.item != null) MiniPlayer(playback, preparation.message != null, { showingPlayer = true }, model::toggle, model::dismissPlayer, followControl.actionFor(playback.item?.id))
                AppNavigation(destination) { tab ->
                    destination = tab; selectedItemId = null; selectedSource = null
                }
            }
        },
        snackbarHost = { SnackbarHost(snackbar) },
    ) { padding ->
        Column(Modifier.fillMaxSize().padding(padding)) {
            if (showingSearch) SearchField(query, { query = it }, when {
                selectedItem != null -> "Find in this page"
                selectedSource != null -> "Search this show"
                destination == Destination.Saved -> "Search saved articles"
                else -> "Search your library"
            })
            when {
                selectedItem != null -> ArticleReader(selectedItem, query, followControl)
                selectedSource != null -> ItemList(model.library.filter { it.source == selectedSource }, saved, query, { selectedItemId = it.id }, model::play, model::toggleSaved, source = selectedSource)
                destination == Destination.Following -> Following(model.library, query, { selectedSource = it }, { selectedItemId = it.id }, pendingSources, model::removePendingSource)
                destination == Destination.Latest -> ItemList(latestItems, saved, "", { selectedItemId = it.id }, model::play, model::toggleSaved, emptyTitle = "You're caught up")
                destination == Destination.Saved -> key(savedListVersion) {
                    ItemList(model.library.filter { it.id in saved && it.kind == ContentKind.Article }, saved, query, { selectedItemId = it.id }, model::play, model::toggleSaved, savedOnly = true, finished = finished, finish = model::toggleFinished,
                        pendingLinks = pendingLinks, removePendingLink = model::removePendingLink)
                }
                else -> SettingsScreen(model) { showingAccount = true }
            }
        }
    }
    if (showingPlayer) ModalBottomSheet(onDismissRequest = { showingPlayer = false }, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
        FullPlayer(playback, preparation, model::toggle, model::skip, model::seek, model::speed,
            sleepTimer, model::startSleepTimer, model::cancelSleepTimer, close = { showingPlayer = false }) {
            selectedItemId = playback.item?.id
            showingPlayer = false
        }
    }
}

@Composable
private fun AppNavigation(selected: Destination, select: (Destination) -> Unit) {
    if (LocalDensity.current.fontScale <= 1.3f) {
        NavigationBar {
            Destination.entries.forEach { tab ->
                NavigationBarItem(selected = selected == tab, onClick = { select(tab) },
                    icon = { Icon(tab.icon, null) }, label = { Text(tab.label) })
            }
        }
    } else {
        // Four narrow columns break long labels at large text sizes. Give each tab half the width.
        Surface(color = MaterialTheme.colorScheme.surfaceContainer) {
            Column(Modifier.fillMaxWidth().navigationBarsPadding().padding(4.dp)) {
                Destination.entries.chunked(2).forEach { row ->
                    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                        row.forEach { tab ->
                            Surface(
                                modifier = Modifier.weight(1f).selectable(selected == tab, role = Role.Tab) { select(tab) },
                                shape = RoundedCornerShape(16.dp),
                                color = if (selected == tab) MaterialTheme.colorScheme.primaryContainer else MaterialTheme.colorScheme.surfaceContainer,
                            ) {
                                Row(Modifier.heightIn(min = 64.dp).padding(10.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                    Icon(tab.icon, null, Modifier.size(24.dp))
                                    Text(tab.label, style = MaterialTheme.typography.labelLarge)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun Following(items: List<LibraryItem>, query: String, openSource: (String) -> Unit, openItem: (LibraryItem) -> Unit, pendingSources: List<String>, removeSource: (String) -> Unit) {
    val visiblePendingSources = pendingSources.filter { it.contains(query, ignoreCase = true) }
    val sources = items.groupBy { it.source }.filterKeys { it.contains(query, ignoreCase = true) }
    val results = if (query.isBlank()) emptyList() else items.filter { "${it.title} ${it.source}".contains(query, ignoreCase = true) }
    LazyColumn(Modifier.fillMaxSize().testTag("following-list")) {
        if (query.isNotBlank() && sources.isNotEmpty()) item { ListSection("In your library") }
        if (visiblePendingSources.isNotEmpty()) item { ListSection("Pending sources") }
        items(visiblePendingSources, key = { "pending-source:$it" }) { url ->
            PendingLinkRow(url, isSource = true) { removeSource(url) }
        }
        if (visiblePendingSources.isNotEmpty() && sources.isNotEmpty()) item { ListSection("Following") }
        items(sources.entries.toList(), key = { it.key }) { (source, stories) ->
            ListItem(
                headlineContent = { Text(source, fontWeight = FontWeight.SemiBold) },
                supportingContent = { Text(sourceCount(stories)) },
                leadingContent = { SourceArtwork(source, Modifier.size(56.dp)) },
                modifier = Modifier.clickable(onClickLabel = "Open $source") { openSource(source) },
            )
            HorizontalDivider(Modifier.padding(start = 88.dp))
        }
        if (results.isNotEmpty()) item { ListSection("Episodes in your library") }
        items(results, key = { it.id }) { item -> StoryRow(item, { openItem(item) }) }
        if (query.isNotBlank() && sources.isEmpty() && results.isEmpty() && visiblePendingSources.isEmpty()) item { EmptyState("Nothing found", "Try a different title or source.") }
    }
}

@Composable
private fun ItemList(items: List<LibraryItem>, saved: Set<String>, query: String, open: (LibraryItem) -> Unit, play: (LibraryItem) -> Unit, save: (LibraryItem) -> Unit, source: String? = null, savedOnly: Boolean = false, finished: Set<String> = emptySet(), finish: (LibraryItem) -> Unit = {}, pendingLinks: List<String> = emptyList(), removePendingLink: (String) -> Unit = {}, emptyTitle: String = "Nothing here yet") {
    var showingFinished by rememberSaveable { mutableStateOf(false) }
    val visible = items.filter { (!savedOnly || (it.id in finished) == showingFinished) && "${it.title} ${it.source}".contains(query, ignoreCase = true) }
    val visibleLinks = if (savedOnly && !showingFinished) pendingLinks.filter { it.contains(query, ignoreCase = true) } else emptyList()
    LazyColumn(Modifier.fillMaxSize().testTag("story-list")) {
        if (savedOnly) item {
            SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp)) {
                listOf("To read", "Finished").forEachIndexed { index, title ->
                    SegmentedButton(selected = showingFinished == (index == 1), onClick = { showingFinished = index == 1 }, shape = SegmentedButtonDefaults.itemShape(index, 2)) { Text(title) }
                }
            }
        }
        if (source != null && query.isBlank()) {
            item { FeedHeader(source, sourceCount(items)) }
            item { ListSection(if (items.all { it.kind == ContentKind.Article }) "Posts" else "Episodes") }
        }
        if (visible.isEmpty() && visibleLinks.isEmpty()) item { EmptyState(if (query.isNotBlank()) "Nothing found" else emptyTitle, if (query.isNotBlank()) "Try a different search." else if (savedOnly && showingFinished) "Articles you finish stay here." else if (savedOnly) "Add a link above to save it for later." else "New episodes from your shows will appear here.") }
        items(visibleLinks, key = { "pending:$it" }) { url -> PendingLinkRow(url) { removePendingLink(url) } }
        items(visible, key = { it.id }) { item ->
            if (item.kind == ContentKind.Article) ActionStoryRow(item, { open(item) }, { play(item) }, item.id in saved,
                { save(item) }, item.id in finished, if (savedOnly) ({ finish(item) }) else null)
            else StoryRow(item, { open(item) }, { play(item) })
        }
    }
}

@Composable
private fun FeedHeader(source: String, count: String) {
    val largeText = LocalDensity.current.fontScale > 1.3f
    Column(Modifier.fillMaxWidth().padding(16.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
        if (largeText) SourceArtwork(source, Modifier.size(88.dp))
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(16.dp), verticalAlignment = Alignment.Top) {
            if (!largeText) SourceArtwork(source, Modifier.size(88.dp))
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(source, style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold, modifier = Modifier.semantics { heading() })
                Text(count, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            FeedManagementMenu(source)
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun FeedManagementMenu(source: String) {
    var expanded by remember { mutableStateOf(false) }
    var managingSources by rememberSaveable(source) { mutableStateOf(false) }
    Box {
        FilledTonalIconButton(onClick = { expanded = true }) {
            Icon(Icons.Rounded.MoreVert, "Manage $source")
        }
        DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            DropdownMenuItem(text = { Text("Manage sources") }, leadingIcon = { Icon(Icons.Rounded.Link, null) },
                onClick = { expanded = false; managingSources = true })
            HorizontalDivider()
            DropdownMenuItem(enabled = false, onClick = {}, leadingIcon = { Icon(Icons.Rounded.RemoveCircleOutline, null) }, text = {
                Column {
                    Text("Unsubscribe")
                    Text("Requires a connected account", style = MaterialTheme.typography.bodySmall)
                }
            })
        }
    }
    if (managingSources) ModalBottomSheet(onDismissRequest = { managingSources = false },
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
        Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp), verticalAlignment = Alignment.CenterVertically) {
            Text("Manage sources", Modifier.weight(1f).semantics { heading() }, style = MaterialTheme.typography.titleLarge)
            IconButton(onClick = { managingSources = false }) { Icon(Icons.Rounded.Close, "Close source management") }
        }
        LazyColumn(Modifier.fillMaxWidth().heightIn(max = 520.dp).testTag("feed-sources-list")) {
            item {
                Text("Combine sources of the same publication into one list. Matching articles appear once and share reading progress.",
                    Modifier.padding(16.dp), style = MaterialTheme.typography.bodyMedium)
            }
            item { Text("Sources in $source", Modifier.padding(16.dp).semantics { heading() }, style = MaterialTheme.typography.titleSmall) }
            item { ListItem(headlineContent = { Text(source) }, supportingContent = { Text("Bundled sample content") }) }
            item {
                Text("This is a sample feed. Combining or separating sources and unsubscribing will be available when your account is connected.",
                    Modifier.padding(16.dp), style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
    }
}

@Composable
private fun StoryRow(item: LibraryItem, open: () -> Unit, play: (() -> Unit)? = null, actions: List<StoryAction> = emptyList(), showActions: (() -> Unit)? = null) {
    val largeText = LocalDensity.current.fontScale > 1.3f
    Column {
    Row(Modifier.fillMaxWidth().padding(end = 4.dp), verticalAlignment = Alignment.CenterVertically) {
        ListItem(
            headlineContent = { Text(item.title, maxLines = if (largeText) Int.MAX_VALUE else 2, overflow = TextOverflow.Ellipsis) },
            supportingContent = {
                Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text(item.source, maxLines = if (largeText) Int.MAX_VALUE else 1, overflow = TextOverflow.Ellipsis)
                    Text(if (item.kind == ContentKind.Article) "${item.text.split(Regex("\\s+")).size} words" else item.durationLabel, style = MaterialTheme.typography.bodySmall)
                    Text(item.description, style = MaterialTheme.typography.bodySmall, maxLines = if (largeText) Int.MAX_VALUE else 2, overflow = TextOverflow.Ellipsis)
                }
            },
            leadingContent = { SourceArtwork(item.source, Modifier.size(56.dp)) },
            modifier = Modifier.weight(1f).combinedClickable(onClickLabel = "Open ${item.title}", onClick = open,
                onLongClickLabel = if (showActions != null) "Article actions" else null, onLongClick = showActions)
                .semantics { customActions = actions.map { action -> CustomAccessibilityAction(action.label) { action.perform(); true } } },
        )
        if (play != null) IconButton(onClick = play) { Icon(Icons.Rounded.PlayCircleOutline, "Play ${item.title}") }
    }
    HorizontalDivider(Modifier.padding(start = 88.dp))
    }
}

private data class StoryAction(val label: String, val icon: ImageVector, val perform: () -> Unit)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ActionStoryRow(item: LibraryItem, open: () -> Unit, play: () -> Unit, saved: Boolean, save: () -> Unit, finished: Boolean, finish: (() -> Unit)?) {
    var expanded by remember { mutableStateOf(false) }
    val saveAction = StoryAction(if (saved) "Dismiss from Saved" else "Save article",
        if (saved) Icons.Rounded.BookmarkRemove else Icons.Rounded.BookmarkAdd, save)
    val finishAction = finish?.let { StoryAction(if (finished) "Mark as unread" else "Mark as read", Icons.Rounded.CheckCircleOutline, it) }
    val actions = listOfNotNull(finishAction, saveAction)
    val currentSave by rememberUpdatedState(saveAction)
    val currentFinish by rememberUpdatedState(finishAction)
    val swipe = rememberSwipeToDismissBoxState(confirmValueChange = { value ->
        when (value) {
            SwipeToDismissBoxValue.StartToEnd -> currentSave.perform()
            SwipeToDismissBoxValue.EndToStart -> currentFinish?.perform()
            SwipeToDismissBoxValue.Settled -> Unit
        }
        // Saving need not remove the row. Return it to rest after performing the action.
        false
    })
    Box {
        SwipeToDismissBox(state = swipe, enableDismissFromEndToStart = finishAction != null,
            backgroundContent = {
                val action = if (swipe.dismissDirection == SwipeToDismissBoxValue.StartToEnd) saveAction else finishAction
                Box(Modifier.fillMaxSize().background(MaterialTheme.colorScheme.secondaryContainer).padding(16.dp),
                    contentAlignment = if (swipe.dismissDirection == SwipeToDismissBoxValue.StartToEnd) Alignment.CenterStart else Alignment.CenterEnd) {
                    if (action != null) Row(Modifier.clearAndSetSemantics {}, verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        Icon(action.icon, null)
                        Text(action.label)
                    }
                }
            }) {
            Surface { StoryRow(item, open, play, actions) { expanded = true } }
        }
        DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            actions.forEach { action ->
                DropdownMenuItem(text = { Text(action.label) }, leadingIcon = { Icon(action.icon, null) },
                    onClick = { expanded = false; action.perform() })
            }
        }
    }
}

private fun sourceCount(items: List<LibraryItem>): String = "${items.size} ${if (items.all { it.kind == ContentKind.Article }) "posts" else "episodes"}"

@Composable
private fun ListSection(title: String) {
    Text(title, Modifier.padding(horizontal = 16.dp, vertical = 12.dp).semantics { heading() }, style = MaterialTheme.typography.titleSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
}

@Composable
internal fun MiniPlayer(state: PlayerState, preparing: Boolean, open: () -> Unit, toggle: () -> Unit,
    dismiss: () -> Unit, follow: (() -> Unit)? = null) {
    val item = state.item ?: return
    Surface(color = MaterialTheme.colorScheme.primaryContainer, contentColor = MaterialTheme.colorScheme.onPrimaryContainer,
        tonalElevation = 2.dp, modifier = Modifier.testTag("mini-player")) {
        Column {
            BoxWithConstraints(Modifier.fillMaxWidth().padding(horizontal = 8.dp)) {
                val expanded = maxWidth < 360.dp || LocalDensity.current.fontScale > 1.3f
                val title: @Composable (Modifier) -> Unit = { modifier ->
                    Row(modifier.heightIn(min = 48.dp).testTag("mini-player-open")
                        .clickable(onClickLabel = "Open player") { open() }.padding(8.dp),
                        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        SourceArtwork(item.source, Modifier.size(32.dp))
                        Text(item.title, style = MaterialTheme.typography.titleSmall, maxLines = if (expanded) 2 else 1,
                            overflow = TextOverflow.Ellipsis)
                    }
                }
                val controls: @Composable () -> Unit = {
                    if (follow != null) IconButton(onClick = follow, modifier = Modifier.size(48.dp)) {
                        Icon(Icons.Rounded.MyLocation, "Follow reading position")
                    }
                    IconButton(onClick = toggle, enabled = state.connected && !preparing, modifier = Modifier.size(48.dp)) {
                        Icon(if (state.playing) Icons.Rounded.Pause else Icons.Rounded.PlayArrow,
                            if (state.playing) "Pause playback" else "Resume playback", Modifier.size(28.dp))
                    }
                    IconButton(onClick = dismiss, enabled = state.connected, modifier = Modifier.size(48.dp)) {
                        Icon(Icons.Rounded.Close, "Stop and close player")
                    }
                }
                if (expanded) Column(Modifier.fillMaxWidth().padding(vertical = 4.dp)) {
                    title(Modifier.fillMaxWidth())
                    Row(Modifier.align(Alignment.End), verticalAlignment = Alignment.CenterVertically) { controls() }
                } else Row(Modifier.fillMaxWidth().heightIn(min = 76.dp), verticalAlignment = Alignment.CenterVertically) {
                    title(Modifier.weight(1f))
                    controls()
                }
            }
            LinearProgressIndicator(progress = {
                if (state.durationMs > 0) (state.positionMs.toFloat() / state.durationMs).coerceIn(0f, 1f) else 0f
            }, modifier = Modifier.fillMaxWidth().height(2.dp).clearAndSetSemantics { },
                color = MaterialTheme.colorScheme.primary, trackColor = MaterialTheme.colorScheme.primary.copy(alpha = .12f),
                gapSize = 0.dp, drawStopIndicator = {})
        }
    }
}

@Composable
private fun PreparationBar(state: Preparation, cancel: () -> Unit) {
    Surface(color = MaterialTheme.colorScheme.surfaceContainerHigh) {
        Row(Modifier.fillMaxWidth().padding(start = 20.dp, end = 8.dp), verticalAlignment = Alignment.CenterVertically) {
            CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp)
            Text(state.message.orEmpty(), Modifier.weight(1f).padding(12.dp).semantics { liveRegion = LiveRegionMode.Polite }, style = MaterialTheme.typography.bodyMedium)
            IconButton(onClick = cancel) { Icon(Icons.Rounded.Close, "Cancel article preparation") }
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun FullPlayer(state: PlayerState, preparing: Preparation, toggle: () -> Unit, skip: (Int) -> Unit, seek: (Long) -> Unit, speed: (Float) -> Unit,
    sleepTimer: SleepTimerState, startSleepTimer: (Int) -> Unit, cancelSleepTimer: () -> Unit, close: () -> Unit, read: () -> Unit) {
    val item = state.item ?: return
    Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(horizontal = 28.dp).padding(bottom = 32.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(20.dp)) {
        IconButton(onClick = close, modifier = Modifier.align(Alignment.End)) { Icon(Icons.Rounded.KeyboardArrowDown, "Close player") }
        SourceArtwork(item.source, Modifier.size(260.dp))
        TextButton(onClick = read) {
            Text(item.title, Modifier.weight(1f), textAlign = TextAlign.Center, style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold, color = MaterialTheme.colorScheme.onSurface)
            Icon(Icons.Rounded.ChevronRight, null)
        }
        if (state.buffering || preparing.message != null) Text(preparing.message ?: "Loading audio…", Modifier.semantics { liveRegion = LiveRegionMode.Polite })
        var scrub by remember { mutableStateOf<Float?>(null) }
        Column {
            Slider(
                value = scrub ?: state.positionMs.toFloat().coerceIn(0f, state.durationMs.toFloat().coerceAtLeast(1f)),
                onValueChange = { scrub = it },
                onValueChangeFinished = { scrub?.let { seek(it.toLong()) }; scrub = null },
                valueRange = 0f..state.durationMs.toFloat().coerceAtLeast(1f),
                enabled = state.durationMs > 0 && preparing.message == null,
                modifier = Modifier.semantics { contentDescription = "Playback position" },
            )
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                Text(formatTime(state.positionMs), style = MaterialTheme.typography.labelLarge)
                Text("−" + formatTime(state.durationMs - state.positionMs), style = MaterialTheme.typography.labelLarge)
            }
        }
        Row(horizontalArrangement = Arrangement.spacedBy(24.dp), verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = { skip(-15) }, enabled = state.durationMs > 0 && preparing.message == null, modifier = Modifier.size(56.dp)) { Icon(Icons.Rounded.Replay, "Back 15 seconds", Modifier.size(32.dp)) }
            FilledIconButton(onClick = toggle, enabled = state.connected && preparing.message == null, modifier = Modifier.size(76.dp)) { Icon(if (state.playing) Icons.Rounded.Pause else Icons.Rounded.PlayArrow, if (state.playing) "Pause" else "Play", Modifier.size(40.dp)) }
            IconButton(onClick = { skip(30) }, enabled = state.durationMs > 0 && preparing.message == null, modifier = Modifier.size(56.dp)) { Icon(Icons.Rounded.Forward30, "Forward 30 seconds", Modifier.size(32.dp)) }
        }
        FlowRow(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(12.dp, Alignment.CenterHorizontally), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            SpeedPicker(state.speed, speed)
            SleepTimerButton(sleepTimer, state.connected, startSleepTimer, cancelSleepTimer)
        }
    }
}

@Composable
private fun SpeedPicker(current: Float, select: (Float) -> Unit) {
    var expanded by remember { mutableStateOf(false) }
    Box {
        OutlinedButton(onClick = { expanded = true }, modifier = Modifier.semantics { contentDescription = "Playback speed, $current times" }) { Icon(Icons.Rounded.Speed, null); Spacer(Modifier.width(8.dp)); Text("${current}×") }
        DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            playbackRates.forEach { speed ->
                DropdownMenuItem(text = { Text("${speed}×") }, onClick = { select(speed); expanded = false }, trailingIcon = { if (speed == current) Icon(Icons.Rounded.Check, "Selected") })
            }
        }
    }
}

@Composable
private fun SearchField(query: String, change: (String) -> Unit, hint: String) {
    OutlinedTextField(query, change, Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp), label = { Text(hint) }, leadingIcon = { Icon(Icons.Rounded.Search, null) }, singleLine = true, shape = RoundedCornerShape(28.dp))
}

@Composable
private fun SourceArtwork(source: String, modifier: Modifier = Modifier) {
    Surface(modifier, shape = RoundedCornerShape(8.dp), color = if (source == "Field notes") MaterialTheme.colorScheme.secondaryContainer else MaterialTheme.colorScheme.primaryContainer) {
        Box(contentAlignment = Alignment.Center) { Icon(if (source == "Field notes") Icons.Rounded.Park else Icons.Rounded.GraphicEq, null, Modifier.fillMaxSize(0.5f)) }
    }
}

@Composable
private fun EmptyState(title: String, message: String) {
    Column(Modifier.fillMaxWidth().padding(horizontal = 24.dp, vertical = 32.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text(title, style = MaterialTheme.typography.titleLarge)
        Text(message, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

private fun formatTime(milliseconds: Long): String {
    val seconds = milliseconds.coerceAtLeast(0) / 1000
    return "%d:%02d".format(seconds / 60, seconds % 60)
}
