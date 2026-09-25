package com.henrydashwood.magpie.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.automirrored.rounded.LibraryBooks
import androidx.compose.material.icons.automirrored.rounded.VolumeUp
import androidx.compose.material.icons.rounded.*
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.zIndex
import androidx.compose.ui.unit.sp
import androidx.compose.material3.*
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.graphics.vector.rememberVectorPainter
import androidx.compose.ui.layout.ContentScale
import coil3.compose.AsyncImage
import com.henrydashwood.magpie.data.ListeningPresentation
import com.henrydashwood.magpie.data.publicationDate
import com.henrydashwood.magpie.data.publisherArtwork
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
import com.henrydashwood.magpie.data.ItemFilingAction
import com.henrydashwood.magpie.data.LibraryItem
import com.henrydashwood.magpie.data.LibraryFeed
import com.henrydashwood.magpie.data.NewsletterState
import kotlinx.coroutines.delay
import com.henrydashwood.magpie.playback.Preparation
import com.henrydashwood.magpie.playback.SleepTimerState
import com.henrydashwood.magpie.shortcuts.*

private enum class Destination(val label: String, val icon: ImageVector) {
    Following("Following", Icons.AutoMirrored.Rounded.LibraryBooks),
    Latest("Latest", Icons.Rounded.Schedule),
    Saved("Saved", Icons.Rounded.BookmarkBorder),
    Settings("Settings", Icons.Rounded.Settings),
}

/** The pull-to-refresh action for TalkBack, attached to a screen's heading. */
private val LocalRefreshActions = compositionLocalOf<List<CustomAccessibilityAction>> { emptyList() }

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MagpieApp(model: MagpieModel, appleReturn: Int = 0, savedReturn: Int = 0,
    shortcut: ShortcutRequest? = null, consumeShortcut: () -> Unit = {}) {
    androidx.lifecycle.compose.LifecycleEventEffect(androidx.lifecycle.Lifecycle.Event.ON_RESUME) {
        // A separate share task may have queued content while this screen was stopped.
        model.savedPreparation.sync()
        if (model.libraryState.value.live) model.newsletters.loadPending()
    }
    val snapshot by model.libraryState.collectAsStateWithLifecycle()
    val newsletterState by model.newsletters.state.collectAsStateWithLifecycle()
    val pendingNewsletterState = newsletterState.takeIf { snapshot.live && it.revision == snapshot.revision }
    val loadingItem by model.itemLoading.collectAsStateWithLifecycle()
    val itemError by model.itemError.collectAsStateWithLifecycle()
    var reloadVersion by remember { mutableIntStateOf(0) }
    var showingAccount by rememberSaveable { mutableStateOf(false) }
    var showingShortcuts by rememberSaveable { mutableStateOf(false) }
    val shortcutNavigation by model.shortcutNavigation.collectAsStateWithLifecycle()
    val shortcutWorking by model.shortcutWorking.collectAsStateWithLifecycle()
    val saved by model.saved.collectAsStateWithLifecycle()
    val finished by model.finished.collectAsStateWithLifecycle()
    val dismissedFromLatest by model.dismissedFromLatest.collectAsStateWithLifecycle()
    val latestItems = if (snapshot.live) snapshot.latestIds.mapNotNull { id -> snapshot.items.find { it.id == id } } else model.library.filter { it.id !in dismissedFromLatest && it.id !in finished }
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
    val selectedItem = snapshot.items.find { it.id == selectedItemId }
    val selectedFeed = snapshot.feeds.find { it.id == selectedSource }
    fun openItem(item: LibraryItem) { selectedItemId = item.id; model.openItem(item) }
    // Each tab keeps its place, as on iOS: leaving a tab and coming back returns to the open
    // show or article. Choosing the tab you are already on goes back to its top level.
    var tabPlaces by rememberSaveable { mutableStateOf(hashMapOf<String, String>()) }
    fun switchTab(tab: Destination) {
        if (tab == destination) { selectedItemId = null; selectedSource = null; return }
        tabPlaces = HashMap(tabPlaces).apply {
            remove("${destination.name}:item"); remove("${destination.name}:source")
            selectedItemId?.let { put("${destination.name}:item", it) }
            selectedSource?.let { put("${destination.name}:source", it) }
        }
        destination = tab
        selectedItemId = tabPlaces["${tab.name}:item"]; selectedSource = tabPlaces["${tab.name}:source"]
    }
    var displayedRevision by rememberSaveable { mutableIntStateOf(snapshot.revision) }
    LaunchedEffect(snapshot.revision) {
        if (displayedRevision != snapshot.revision) {
            displayedRevision = snapshot.revision
            selectedItemId = null; selectedSource = null; showingPlayer = false; query = ""; tabPlaces = hashMapOf()
        }
    }
    LaunchedEffect(snapshot.revision, snapshot.owner, snapshot.catalogRevision, selectedSource, query, destination, reloadVersion) {
        if (snapshot.live && snapshot.owner != null && selectedItemId == null &&
            (selectedSource != null || destination == Destination.Following) && (selectedSource == null || selectedFeed != null)) {
            if (query.isNotBlank()) delay(300)
            model.searchLibrary(selectedSource, query)
        }
    }
    LaunchedEffect(snapshot.catalogRevision) {
        if (snapshot.live && snapshot.catalogRevision > 0 && selectedSource != null && selectedFeed == null) selectedSource = null
    }
    LaunchedEffect(destination, snapshot.owner) { if (destination == Destination.Saved) model.savedPreparation.sync() }
    LaunchedEffect(destination, snapshot.revision, newsletterState.revision, snapshot.live) {
        if (snapshot.live && snapshot.revision == newsletterState.revision && destination in setOf(Destination.Following, Destination.Latest)) model.newsletters.loadPending()
    }
    val snackbar = remember { SnackbarHostState() }
    val followControl = remember { ArticleFollowControl() }
    LaunchedEffect(savedReturn) {
        if (savedReturn > 0) {
            showingAccount = false; selectedItemId = null; selectedSource = null; showingPlayer = false
            destination = Destination.Saved; query = ""; showingSearch = false
            model.refreshLibrary()
        }
    }
    LaunchedEffect(appleReturn) { if (appleReturn > 0) showingAccount = true }
    LaunchedEffect(shortcut?.delivery) {
        shortcut?.let {
            showingAccount = false; showingShortcuts = false; showingPlayer = false
            model.runShortcut(it); consumeShortcut()
        }
    }
    LaunchedEffect(shortcutNavigation) {
        shortcutNavigation?.let { request ->
            // The account/catalog can change after the model resolved the route
            // but before Compose consumes it on the next frame.
            val current = model.libraryState.value
            val currentOwner = current.owner ?: if (!current.live) "sample" else null
            if ((request.owner != null && request.owner != currentOwner) ||
                (request.action == ShortcutAction.OpenFeed && current.feeds.none { it.id == request.feedId })) {
                model.consumeShortcutNavigation()
                return@let
            }
            showingAccount = false; showingShortcuts = false; showingPlayer = false
            selectedItemId = null; selectedSource = null; query = ""; showingSearch = false
            when (request.action) {
                ShortcutAction.Saved -> destination = Destination.Saved
                ShortcutAction.Following -> destination = Destination.Following
                ShortcutAction.OpenLatest -> destination = Destination.Latest
                ShortcutAction.OpenFeed -> { destination = Destination.Following; selectedSource = request.feedId }
                ShortcutAction.Shortcuts -> showingShortcuts = true
                ShortcutAction.ReadItem -> selectedItemId = request.itemId
                ShortcutAction.Ask, ShortcutAction.RunRequest -> Unit
                else -> showingPlayer = playback.item != null
            }
            model.consumeShortcutNavigation()
        }
    }
    if (showingAccount) {
        BackHandler { showingAccount = false }
        com.henrydashwood.magpie.auth.AccountScreen(onBack = { showingAccount = false })
        return
    }
    if (showingShortcuts) {
        BackHandler { showingShortcuts = false }
        ShortcutsScreen(model) { showingShortcuts = false }
        return
    }
    LaunchedEffect(playback.item) { if (playback.item == null) showingPlayer = false }
    LaunchedEffect(notice) { notice?.let { snackbar.showSnackbar(it); model.dismissNotice() } }
    LaunchedEffect(preparation.error) { preparation.error?.let { snackbar.showSnackbar(it, duration = SnackbarDuration.Long) } }
    BackHandler(showingSearch || selectedItem != null || selectedSource != null) {
        if (showingSearch) { showingSearch = false; query = ""; return@BackHandler }
        if (selectedItem != null) selectedItemId = null else selectedSource = null
    }

    // Pull to refresh, as on iOS. TalkBack cannot perform the pull, so the screen's heading
    // carries the same refresh as a custom action.
    val refreshable = snapshot.live && selectedItem == null && destination != Destination.Settings
    fun refresh() { if (!snapshot.loading && !snapshot.searching) { model.refreshLibrary(); reloadVersion++ } }
    val refreshActions = if (refreshable) listOf(CustomAccessibilityAction("Refresh library") { refresh(); true }) else emptyList()
    // As on iOS, an article runs under the bars, which fade while she reads down the page and
    // return when she scrolls back up. Anything shown above the article keeps them in place.
    val filing by model.itemFiling.state.collectAsStateWithLifecycle()
    val readingArticle = selectedItem != null && !(snapshot.live && !selectedItem.textLoaded)
    val underBars = readingArticle && !showingSearch && shortcutWorking == null && !filing.busy && filing.error == null
    var chromeHidden by remember(selectedItemId) { mutableStateOf(false) }
    LaunchedEffect(underBars) { if (!underBars) chromeHidden = false }
    val chromeAlpha by animateFloatAsState(if (chromeHidden && underBars) 0f else 1f, tween(250, easing = FastOutSlowInEasing), label = "reader bars")
    // Faded bars leave the layout, so a touch there reaches the page rather than an invisible button.
    val chromeShown = chromeAlpha > 0.01f
    var barInsets by remember { mutableStateOf(0.dp to 0.dp) }
    Scaffold(
        topBar = {
            if (chromeShown) TopAppBar(
                modifier = Modifier.graphicsLayer { alpha = chromeAlpha },
                title = {
                    if (selectedItem == null && selectedSource == null)
                        Text(destination.label, Modifier.semantics { heading(); customActions = refreshActions })
                },
                navigationIcon = {
                    if (selectedItem != null || selectedSource != null) IconButton(onClick = {
                        if (selectedItem != null) selectedItemId = null else selectedSource = null
                    }) { Icon(Icons.AutoMirrored.Rounded.ArrowBack, "Back") }
                },
                actions = {
                    if (selectedItem == null && selectedSource == null && destination == Destination.Following) {
                        AddSourceButton(model, ::openItem) { showingSearch = false; query = "" }
                    }
                    if (selectedItem == null && selectedSource == null && destination == Destination.Saved) {
                        AddLinkButton(model) { savedListVersion++; showingSearch = false; query = "" }
                    }
                    if (selectedItem != null) {
                        val isPlaying = playback.item?.id == selectedItem.id && playback.playing
                        ReaderToolbarActions(selectedItem, isPlaying, showingSearch,
                            { if (isPlaying) model.pause() else model.play(selectedItem) },
                            { showingSearch = !showingSearch; query = "" }, onAsk = { model.ask(selectedItem.episodeId) })
                    } else if (selectedSource != null || destination == Destination.Following || destination == Destination.Saved) {
                        IconButton(onClick = { showingSearch = !showingSearch; query = "" }) {
                            Icon(if (showingSearch) Icons.Rounded.Close else Icons.Rounded.Search,
                                if (showingSearch) "Close search" else "Search")
                        }
                    }
                    if (selectedItem == null && selectedSource == null && destination == Destination.Latest && latestItems.isNotEmpty()) {
                        ClearLatestButton(model)
                    }
                    if (selectedItem == null) AskMagpieButton { model.ask() }
                },
            )
        },
        bottomBar = {
            if (chromeShown) Column(Modifier.graphicsLayer { alpha = chromeAlpha }) {
                if (preparation.message != null) PreparationBar(preparation, model::cancelPreparation)
                if (playback.item != null) MiniPlayer(playback, preparation.message != null, { showingPlayer = true }, model::toggle, model::dismissPlayer, followControl.actionFor(playback.item?.id))
                AppNavigation(destination, ::switchTab)
            }
        },
        snackbarHost = { SnackbarHost(snackbar) },
    ) { padding ->
        val layoutDirection = LocalLayoutDirection.current
        SideEffect { if (chromeShown) barInsets = padding.calculateTopPadding() to padding.calculateBottomPadding() }
        val chrome = if (!underBars) ReaderChrome() else ReaderChrome(barInsets.first.value, barInsets.second.value,
            fades = true, hidden = chromeHidden, onHidden = { chromeHidden = it })
        Box(Modifier.fillMaxSize()) {
        // The status bar keeps a background of its own, so text never runs under the clock.
        if (underBars) Box(Modifier.fillMaxWidth().windowInsetsTopHeight(WindowInsets.statusBars)
            .background(MaterialTheme.colorScheme.surface).zIndex(1f))
        Column(Modifier.fillMaxSize().padding(if (!underBars) padding else PaddingValues(
            start = padding.calculateStartPadding(layoutDirection), end = padding.calculateEndPadding(layoutDirection)))) {
            ItemFilingStatus(model)
            shortcutWorking?.let { action ->
                Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp), verticalAlignment = Alignment.CenterVertically) {
                    Text("$action…", Modifier.weight(1f).semantics { liveRegion = LiveRegionMode.Polite })
                    TextButton(onClick = model::cancelShortcut) { Text("Cancel") }
                }
            }
            if (showingSearch) SearchField(query, { query = it }, when {
                selectedItem != null -> "Find in this page"
                selectedSource != null -> "Search this show"
                destination == Destination.Saved -> "Search saved articles"
                else -> "Search your library"
            })
            if (snapshot.live && destination != Destination.Settings && selectedItem == null) {
                if (snapshot.loading || snapshot.searching) LinearProgressIndicator(Modifier.fillMaxWidth().semantics { contentDescription = "Loading library" })
                snapshot.error?.let { error ->
                    Column(Modifier.padding(16.dp)) {
                        Text(error, color = MaterialTheme.colorScheme.error, modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite })
                        TextButton(onClick = ::refresh) { Text("Try again") }
                    }
                }
            }
            val screen: @Composable () -> Unit = { when {
                selectedItem != null && snapshot.live && !selectedItem.textLoaded -> Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    if (loadingItem == selectedItem.id) { CircularProgressIndicator(); Text("Loading article…") }
                    else {
                        Text(itemError ?: selectedItem.captureError ?: "Open this article to load its text.", modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite })
                        TextButton(onClick = { model.openItem(selectedItem) }) { Text("Try again") }
                    }
                }
                selectedItem != null -> ArticleReader(selectedItem, query, followControl, chrome)
                selectedSource != null -> ItemList(if (snapshot.live) snapshot.feedResults.mapNotNull { id -> snapshot.items.find { it.id == id } } else model.library.filter { it.source == selectedSource }, saved, if (snapshot.live) "" else query, ::openItem, model::play, model::toggleSaved, source = selectedFeed?.title ?: selectedSource, live = snapshot.live,
                    feedSources = selectedFeed?.sources.orEmpty(), feed = selectedFeed, model = model, loading = snapshot.loading || snapshot.searching || snapshot.error != null)
                destination == Destination.Following -> Following(snapshot.feeds, if (snapshot.live) snapshot.searchResults.mapNotNull { id -> snapshot.items.find { it.id == id } } else model.library, query, { selectedSource = it }, ::openItem, pendingSources, model::removePendingSource, snapshot.live, snapshot.loading || snapshot.searching || snapshot.error != null, model, pendingNewsletterState)
                destination == Destination.Latest -> ItemList(latestItems, saved, "", ::openItem, model::play, model::toggleSaved, emptyTitle = "You're caught up", loading = snapshot.loading || snapshot.error != null, model = model, newsletters = pendingNewsletterState, showContinuation = true)
                destination == Destination.Saved -> key(savedListVersion) {
                    ItemList(if (snapshot.live) snapshot.savedIds.mapNotNull { id -> snapshot.items.find { it.id == id } } else model.library.filter { it.id in saved && it.kind == ContentKind.Article }, saved, query, ::openItem, model::play, model::toggleSaved, savedOnly = true, finished = finished, finish = model::toggleFinished,
                        pendingLinks = pendingLinks, removePendingLink = model::removePendingLink, live = snapshot.live, model = model, loading = snapshot.loading || snapshot.error != null)
                }
                else -> SettingsScreen(model, onShortcuts = { showingShortcuts = true }) { showingAccount = true }
            } }
            if (refreshable) CompositionLocalProvider(LocalRefreshActions provides refreshActions) {
                PullToRefreshBox(isRefreshing = snapshot.loading || snapshot.searching, onRefresh = ::refresh,
                    modifier = Modifier.fillMaxSize().testTag("pull-to-refresh")) { screen() }
            } else screen()
        }
        }
    }
    SubscriptionImportDialog(model) {
        destination = Destination.Following
        selectedSource = null
        selectedItemId = null
        query = ""
        model.refreshLibrary()
    }
    SourceManagementDialog(model)
    ReplaceSavedTextDialog(model)
    AskConversation(model)
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
private fun Following(feeds: List<LibraryFeed>, items: List<LibraryItem>, query: String, openSource: (String) -> Unit, openItem: (LibraryItem) -> Unit, pendingSources: List<String>, removeSource: (String) -> Unit, live: Boolean = false, loading: Boolean = false, model: MagpieModel? = null, newsletters: NewsletterState? = null) {
    val visiblePendingSources = pendingSources.filter { it.contains(query, ignoreCase = true) }
    val sources = feeds.filter { it.title.contains(query, ignoreCase = true) }
    val results = if (query.isBlank()) emptyList() else if (live) items else items.filter { "${it.title} ${it.source}".contains(query, ignoreCase = true) }
    LazyColumn(Modifier.fillMaxSize().testTag("following-list")) {
        if (model != null && newsletters != null && query.isBlank()) pendingNewsletters(model, newsletters)
        if (query.isNotBlank() && sources.isNotEmpty()) item { ListSection("In your library") }
        if (visiblePendingSources.isNotEmpty()) item { ListSection("Pending sources") }
        items(visiblePendingSources, key = { "pending-source:$it" }) { url ->
            PendingLinkRow(url, isSource = true) { removeSource(url) }
        }
        if (visiblePendingSources.isNotEmpty() && sources.isNotEmpty()) item { ListSection("Following") }
        items(sources, key = { it.id }) { source ->
            ListItem(
                headlineContent = { Text(source.title, fontWeight = FontWeight.SemiBold) },
                supportingContent = { Text("${source.count} ${if (source.articles) "posts" else "episodes"}") },
                leadingContent = { SourceArtwork(source.title, Modifier.size(56.dp), source.imageUrl) },
                modifier = Modifier.clickable(onClickLabel = "Open ${source.title}") { openSource(source.id) },
            )
            HorizontalDivider(Modifier.padding(start = 88.dp))
        }
        if (results.isNotEmpty()) item { ListSection("Episodes in your library") }
        items(results, key = { it.id }) { item ->
            if (model != null) LibraryStoryRow(model, item, { openItem(item) }, { model.play(item) })
            else StoryRow(item, { openItem(item) })
        }
        if (!loading && query.isBlank() && sources.isEmpty() && visiblePendingSources.isEmpty()) item { EmptyState("No sources yet", "Add a feed address above to start following.") }
        if (!loading && query.isNotBlank() && sources.isEmpty() && results.isEmpty() && visiblePendingSources.isEmpty()) item { EmptyState("Nothing found", "Try a different title or source.") }
    }
}

@Composable
private fun ItemList(items: List<LibraryItem>, saved: Set<String>, query: String, open: (LibraryItem) -> Unit, play: (LibraryItem) -> Unit, save: (LibraryItem) -> Unit, source: String? = null, savedOnly: Boolean = false, finished: Set<String> = emptySet(), finish: (LibraryItem) -> Unit = {}, pendingLinks: List<String> = emptyList(), removePendingLink: (String) -> Unit = {}, emptyTitle: String = "Nothing here yet", live: Boolean = false, feedSources: List<String> = emptyList(), loading: Boolean = false, feed: LibraryFeed? = null, model: MagpieModel? = null, newsletters: NewsletterState? = null, showContinuation: Boolean = false) {
    var showingFinished by rememberSaveable { mutableStateOf(false) }
    val preparation = if (savedOnly && live) model?.savedPreparation?.state?.collectAsStateWithLifecycle()?.value else null
    val pending = if (!showingFinished) preparation?.pending.orEmpty().filter { it.url.contains(query, ignoreCase = true) } else emptyList()
    val visible = items.filter { (!savedOnly || (it.id in finished) == showingFinished) && "${it.title} ${it.source}".contains(query, ignoreCase = true) }
    val playback = model?.player?.collectAsStateWithLifecycle()?.value
    val started = if (showContinuation && model != null && playback != null) visible.filter { model.listeningPresentation(it, playback).started } else emptyList()
    val rest = if (started.isEmpty()) visible else visible.filterNot { row -> started.any { it.id == row.id } }
    fun LazyListScope.storyRows(rows: List<LibraryItem>) {
        items(rows, key = { it.id }) { item ->
            if (model != null) LibraryStoryRow(model, item, { open(item) }, { play(item) }, allowsDismissal = source == null, savedList = savedOnly)
            else StoryRow(item, { open(item) }, { play(item) })
            if (savedOnly && live && model != null && item.kind == ContentKind.Article) SavedArticlePreparation(item, model)
        }
    }
    val visibleLinks = if (savedOnly && !showingFinished) pendingLinks.filter { it.contains(query, ignoreCase = true) } else emptyList()
    LazyColumn(Modifier.fillMaxSize().testTag("story-list")) {
        if (model != null && newsletters != null) pendingNewsletters(model, newsletters)
        if (savedOnly) item {
            SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp)) {
                listOf("To read", "Finished").forEachIndexed { index, title ->
                    SegmentedButton(selected = showingFinished == (index == 1), onClick = { showingFinished = index == 1 }, shape = SegmentedButtonDefaults.itemShape(index, 2)) { Text(title) }
                }
            }
        }
        if (source != null && query.isBlank()) {
            item { FeedHeader(source, feed?.let { "${it.count} ${if (it.articles) "posts" else "episodes"}" } ?: sourceCount(items), live, feedSources, feed, model) }
            item { ListSection(if (items.all { it.kind == ContentKind.Article }) "Posts" else "Episodes") }
        }
        if (preparation != null && model != null) item { SavedPreparationStatus(model) }
        if (!loading && visible.isEmpty() && visibleLinks.isEmpty() && pending.isEmpty()) item { EmptyState(if (query.isNotBlank()) "Nothing found" else emptyTitle, if (query.isNotBlank()) "Try a different search." else if (savedOnly && showingFinished) "Articles you finish stay here." else if (savedOnly) "Add a link above to save it for later." else "New episodes from your shows will appear here.") }
        items(pending, key = { "account-pending:${it.id}" }) { if (model != null) SavedPendingRow(it, model) }
        items(visibleLinks, key = { "pending:$it" }) { url -> PendingLinkRow(url) { removePendingLink(url) } }
        if (started.isNotEmpty()) {
            item(key = "continue-heading") { ListSection("Continue listening") }
            storyRows(started)
            if (rest.isNotEmpty()) item(key = "latest-heading") { ListSection("Latest") }
        }
        storyRows(rest)
    }
}

@Composable
private fun FeedHeader(source: String, count: String, live: Boolean = false, sources: List<String> = emptyList(), feed: LibraryFeed? = null, model: MagpieModel? = null) {
    val largeText = LocalDensity.current.fontScale > 1.3f
    Column(Modifier.fillMaxWidth().padding(16.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
        if (largeText) SourceArtwork(source, Modifier.size(88.dp), feed?.imageUrl)
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(16.dp), verticalAlignment = Alignment.Top) {
            if (!largeText) SourceArtwork(source, Modifier.size(88.dp), feed?.imageUrl)
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                val refreshActions = LocalRefreshActions.current
                Text(source, style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold, modifier = Modifier.semantics { heading(); customActions = refreshActions })
                Text(count, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            if (live && feed != null && model != null) SourceManagementMenu(model, feed) else FeedManagementMenu(source, live, sources)
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun FeedManagementMenu(source: String, live: Boolean, sources: List<String>) {
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
                    Text(if (live) "Not available on Android yet" else "Requires a connected account", style = MaterialTheme.typography.bodySmall)
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
            items(if (live) sources.ifEmpty { listOf(source) } else listOf(source)) { name -> ListItem(headlineContent = { Text(name) }, supportingContent = { Text(if (live) "Connected source" else "Bundled sample content") }) }
            item {
                Text(if (live) "Combining, separating, and unsubscribing from sources are not available on Android yet." else "This is a sample feed. Combining or separating sources and unsubscribing will be available when your account is connected.",
                    Modifier.padding(16.dp), style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
    }
}

@Composable
private fun StoryRow(item: LibraryItem, open: () -> Unit, play: (() -> Unit)? = null, actions: List<StoryAction> = emptyList(), showActions: (() -> Unit)? = null, progress: ListeningPresentation? = null, currentLabel: String? = null) {
    val largeText = LocalDensity.current.fontScale > 1.3f
    Column {
    Row(Modifier.fillMaxWidth().padding(end = 4.dp), verticalAlignment = Alignment.CenterVertically) {
        ListItem(
            headlineContent = { Text(item.title, maxLines = if (largeText) Int.MAX_VALUE else 2, overflow = TextOverflow.Ellipsis) },
            supportingContent = {
                Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text(item.source, maxLines = if (largeText) Int.MAX_VALUE else 1, overflow = TextOverflow.Ellipsis)
                    Text(if (item.kind == ContentKind.Article) (item.wordCount ?: if (item.textLoaded) item.text.split(Regex("\\s+")).size else null)?.let { "$it words" } ?: "Article" else item.durationLabel, style = MaterialTheme.typography.bodySmall)
                    publicationDate(item.publishedAt)?.let { Text(it, style = MaterialTheme.typography.bodySmall) }
                    listOfNotNull(currentLabel, progress?.label, "Dismissed".takeIf { item.dismissed }).takeIf { it.isNotEmpty() }?.let {
                        Text(it.joinToString(" · "), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.primary)
                    }
                    progress?.fraction?.takeIf { it > 0 && it < 1 }?.let { fraction ->
                        LinearProgressIndicator(progress = { fraction }, modifier = Modifier.fillMaxWidth().clearAndSetSemantics { })
                    }
                    Text(item.description, style = MaterialTheme.typography.bodySmall, maxLines = if (largeText) Int.MAX_VALUE else 2, overflow = TextOverflow.Ellipsis)
                }
            },
            leadingContent = { SourceArtwork(item.source, Modifier.size(56.dp), item.imageUrl) },
            modifier = Modifier.weight(1f).combinedClickable(onClickLabel = "Open ${item.title}", onClick = open,
                onLongClickLabel = if (showActions != null) "Item actions" else null, onLongClick = showActions)
                .semantics { customActions = actions.filter { it.enabled }.map { action -> CustomAccessibilityAction(action.label) { action.perform(); true } } },
        )
        if (play != null) IconButton(onClick = play, modifier = Modifier.size(48.dp)) {
            Icon(if (currentLabel == "Playing") Icons.AutoMirrored.Rounded.VolumeUp else Icons.Rounded.PlayCircleOutline, "Play ${item.title}")
        }
    }
    HorizontalDivider(Modifier.padding(start = 88.dp))
    }
}

private data class StoryAction(val label: String, val icon: ImageVector, val perform: () -> Unit, val enabled: Boolean = true)

@Composable
private fun filingActions(model: MagpieModel, item: LibraryItem): List<StoryAction> {
    val finished by model.finished.collectAsStateWithLifecycle()
    val dismissed by model.dismissedFromLatest.collectAsStateWithLifecycle()
    val filing by model.itemFiling.state.collectAsStateWithLifecycle()
    val complete = item.id in finished
    val read = item.kind == ContentKind.Article
    return listOf(
        StoryAction(if (complete) { if (read) "Mark as unread" else "Mark as unplayed" }
            else { if (read) "Mark as read" else "Mark as played" }, Icons.Rounded.CheckCircleOutline,
            { model.toggleFinished(item) }, !filing.busy),
        if (item.dismissed || item.id in dismissed) StoryAction("Restore to Latest", Icons.Rounded.Restore,
            { model.fileItem(item, ItemFilingAction.Restore) }, !filing.busy)
        else StoryAction("Dismiss from Latest", Icons.Rounded.RemoveCircleOutline,
            { model.fileItem(item, ItemFilingAction.Dismiss) }, !filing.busy),
    )
}

@Composable
private fun LibraryStoryRow(model: MagpieModel, item: LibraryItem, open: () -> Unit, play: () -> Unit, allowsDismissal: Boolean = false, savedList: Boolean = false) {
    val saved by model.saved.collectAsStateWithLifecycle()
    val actions = filingActions(model, item)
    val save = if (item.kind == ContentKind.Article) StoryAction(
        if (item.id in saved) "Dismiss from Saved" else "Save article",
        if (item.id in saved) Icons.Rounded.BookmarkRemove else Icons.Rounded.BookmarkAdd,
        { model.toggleSaved(item) }) else null
    val playback by model.player.collectAsStateWithLifecycle()
    val preparation by model.preparation.collectAsStateWithLifecycle()
    val finished by model.finished.collectAsStateWithLifecycle()
    val progress = remember(item, playback, finished) { model.listeningPresentation(item, playback) }
    val currentLabel = if (preparation.itemId == item.id && preparation.message != null) "Preparing"
        else if (playback.item?.id != item.id) null else if (playback.buffering) "Preparing" else if (playback.playing) "Playing" else "Paused"
    val dismissed by model.dismissedFromLatest.collectAsStateWithLifecycle()
    val isDismissed = item.dismissed || item.id in dismissed
    // Match iOS: leading dismisses on Latest/Saved; trailing completes or restores.
    val leading = (if (savedList) save else actions.last()).takeIf { allowsDismissal && !isDismissed }
    val trailing = if (isDismissed) actions.last() else actions.first()
    ActionStoryRow(item, open, play, listOfNotNull(actions.first(), save) + actions.drop(1), leading, trailing, progress, currentLabel)
}

@Composable
private fun ItemFilingStatus(model: MagpieModel) {
    val state by model.itemFiling.state.collectAsStateWithLifecycle()
    if (state.busy || state.error != null) Column(Modifier.fillMaxWidth().heightIn(max = 240.dp).verticalScroll(rememberScrollState()).padding(16.dp)) {
        Text(state.error ?: "Updating ${state.item?.title}…", modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite },
            color = if (state.error != null) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurface)
        if (state.error != null) {
            TextButton(onClick = model.itemFiling::retry) { Text("Retry change") }
            TextButton(onClick = model::reviewSavedRequests) { Text("Check saved requests") }
            TextButton(onClick = model.itemFiling::dismissError) { Text("Close message") }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ActionStoryRow(item: LibraryItem, open: () -> Unit, play: () -> Unit,
    actions: List<StoryAction>, leadingAction: StoryAction?, trailingAction: StoryAction?, progress: ListeningPresentation, currentLabel: String?) {
    var expanded by remember(item.id) { mutableStateOf(false) }
    val currentLeading by rememberUpdatedState(leadingAction)
    val currentTrailing by rememberUpdatedState(trailingAction)
    val swipe = rememberSwipeToDismissBoxState(confirmValueChange = { value ->
        when (value) {
            SwipeToDismissBoxValue.StartToEnd -> currentLeading?.takeIf { it.enabled }?.perform()
            SwipeToDismissBoxValue.EndToStart -> currentTrailing?.takeIf { it.enabled }?.perform()
            SwipeToDismissBoxValue.Settled -> Unit
        }
        // Filing need not remove the row from this list. Return it to rest.
        false
    })
    Box {
        SwipeToDismissBox(state = swipe, enableDismissFromStartToEnd = leadingAction?.enabled == true, enableDismissFromEndToStart = trailingAction?.enabled == true,
            backgroundContent = {
                val action = if (swipe.dismissDirection == SwipeToDismissBoxValue.StartToEnd) leadingAction else trailingAction
                Box(Modifier.fillMaxSize().background(MaterialTheme.colorScheme.secondaryContainer).padding(16.dp),
                    contentAlignment = if (swipe.dismissDirection == SwipeToDismissBoxValue.StartToEnd) Alignment.CenterStart else Alignment.CenterEnd) {
                    if (action != null) Row(Modifier.clearAndSetSemantics {}, verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        Icon(action.icon, null)
                        Text(action.label)
                    }
                }
            }) {
            Surface { StoryRow(item, open, play, actions, { expanded = true }, progress, currentLabel) }
        }
        DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            actions.forEach { action ->
                DropdownMenuItem(enabled = action.enabled, text = { Text(action.label) }, leadingIcon = { Icon(action.icon, null) },
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
                        SourceArtwork(item.source, Modifier.size(32.dp), item.imageUrl)
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
        SourceArtwork(item.source, Modifier.size(260.dp), item.imageUrl)
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
            IconButton(onClick = { skip(-15) }, enabled = state.durationMs > 0 && preparing.message == null, modifier = Modifier.size(56.dp)) { SkipBack15() }
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
        val spoken = if (current == 1f) "Normal speed" else "${speedLabel(current).dropLast(1)} times speed"
        OutlinedButton(onClick = { expanded = true }, modifier = Modifier.semantics { contentDescription = "Playback speed, $spoken" }) { Icon(Icons.Rounded.Speed, null); Spacer(Modifier.width(8.dp)); Text(speedLabel(current)) }
        DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            playbackRates.forEach { speed ->
                DropdownMenuItem(text = { Text(speedLabel(speed)) }, onClick = { select(speed); expanded = false }, trailingIcon = { if (speed == current) Icon(Icons.Rounded.Check, "Selected") })
            }
        }
    }
}

@Composable
private fun SearchField(query: String, change: (String) -> Unit, hint: String) {
    OutlinedTextField(query, change, Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp), label = { Text(hint) }, leadingIcon = { Icon(Icons.Rounded.Search, null) }, singleLine = true, shape = RoundedCornerShape(28.dp))
}

@Composable
private fun SourceArtwork(source: String, modifier: Modifier = Modifier, url: String? = null) {
    val placeholder = rememberVectorPainter(if (source == "Field notes") Icons.Rounded.Park else Icons.Rounded.GraphicEq)
    Surface(modifier, shape = RoundedCornerShape(8.dp), color = if (source == "Field notes") MaterialTheme.colorScheme.secondaryContainer else MaterialTheme.colorScheme.primaryContainer) {
        Box(contentAlignment = Alignment.Center) {
            val image = publisherArtwork(url)
            if (image == null) Icon(if (source == "Field notes") Icons.Rounded.Park else Icons.Rounded.GraphicEq, null, Modifier.fillMaxSize(0.5f))
            else AsyncImage(model = image, contentDescription = null, placeholder = placeholder, error = placeholder,
                contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize())
        }
    }
}

@Composable
private fun EmptyState(title: String, message: String) {
    Column(Modifier.fillMaxWidth().padding(horizontal = 24.dp, vertical = 32.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text(title, style = MaterialTheme.typography.titleLarge)
        Text(message, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

/** Material has no "replay 15" icon; this matches Forward30 with the number inside the arrow, as iOS does. */
@Composable
private fun SkipBack15() {
    Box(Modifier.size(32.dp).semantics(mergeDescendants = true) { contentDescription = "Back 15 seconds" }, contentAlignment = Alignment.Center) {
        Icon(Icons.Rounded.Replay, null, Modifier.size(32.dp))
        Text("15", fontSize = 8.sp, fontWeight = FontWeight.Bold, modifier = Modifier.padding(top = 3.dp).clearAndSetSemantics { })
    }
}

/** m:ss, or h:mm:ss from an hour, as on iOS. */
internal fun formatTime(milliseconds: Long): String {
    val seconds = milliseconds.coerceAtLeast(0) / 1000
    return if (seconds >= 3600) "%d:%02d:%02d".format(seconds / 3600, seconds / 60 % 60, seconds % 60)
    else "%d:%02d".format(seconds / 60, seconds % 60)
}
