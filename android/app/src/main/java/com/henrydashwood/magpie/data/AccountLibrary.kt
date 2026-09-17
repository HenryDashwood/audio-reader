package com.henrydashwood.magpie.data

import com.henrydashwood.magpie.auth.AccountFailure
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.io.IOException
import java.security.MessageDigest

data class LibraryState(val live: Boolean = false, val revision: Int = 0, val catalogRevision: Int = 0, val owner: String? = null,
    val items: List<LibraryItem> = emptyList(), val feeds: List<LibraryFeed> = emptyList(),
    val latestIds: List<String> = emptyList(), val savedIds: List<String> = emptyList(),
    val feedItems: Map<String, List<String>> = emptyMap(),
    val feedResults: List<String> = emptyList(), val searchResults: List<String> = emptyList(),
    val loading: Boolean = false, val searching: Boolean = false, val error: String? = null)

/** Main-dispatcher state. Every result is bound to the initiating session revision.
 * Account snapshots survive process recreation; a failed load never falls back to samples. */
class AccountLibrary(private val api: LibraryApi, private val server: String, initiallySignedIn: Boolean = false,
    private val identityStore: AccountIdentityStore? = null, private val cache: LibraryCache? = null, private val progressQueue: PodcastProgressQueue? = null,
    conversationStore: com.henrydashwood.magpie.voice.ConversationStore? = null, private val articleQueue: ArticleProgressQueue? = null,
    telemetryStore: com.henrydashwood.magpie.telemetry.TelemetryStore? = null,
    private val telemetryEnabled: () -> Boolean = { true }) : SubscriptionImportRepository, SourceRepository, SourceManagementRepository, SavedArticleRepository, NewsletterRepository {
    override val importSession: String? get() = state.value.owner?.let { "$it:$revision" }
    override suspend fun currentImport(): ImportJob? {
        val (credential, version) = credentials()
        val result = checkNotNull(api as? SubscriptionImportApi).currentImport(credential)
        check(version)
        return result
    }
    override suspend fun previewImport(bytes: ByteArray): ImportJob {
        val (credential, version) = credentials()
        val result = checkNotNull(api as? SubscriptionImportApi).previewImport(credential, bytes)
        check(version)
        return result
    }
    override suspend fun mutateImport(id: String, action: String, requestId: String?, entries: Set<Int>?): ImportJob {
        val (credential, version) = credentials()
        val result = checkNotNull(api as? SubscriptionImportApi).mutateImport(credential, id, action, requestId, entries)
        check(version)
        return result
    }
    private var token: String? = null
    private var revision = 0
    private var searchVersion = 0
    private val writes = Mutex()
    private val cacheWrites = Mutex()
    private var progressMutation = 0
    private val mutable = MutableStateFlow(if (initiallySignedIn) LibraryState(live = true, loading = true) else preview())
    val state = mutable.asStateFlow()
    fun telemetryScope(): com.henrydashwood.magpie.telemetry.TelemetryScope? {
        if (!telemetryEnabled()) return null
        val owner = state.value.owner ?: return null
        val credential = token ?: return null
        if (api !is com.henrydashwood.magpie.telemetry.TelemetryApi) return null
        return com.henrydashwood.magpie.telemetry.TelemetryScope(owner, revision, digest(server + ":" + credential))
    }
    val telemetry = telemetryStore?.let { storage -> com.henrydashwood.magpie.telemetry.TelemetryQueue(storage, ::telemetryScope, { expected, event ->
        check(telemetryScope() == expected)
        val credential = checkNotNull(token)
        (api as com.henrydashwood.magpie.telemetry.TelemetryApi).reportTelemetry(credential, event)
        check(telemetryScope() == expected)
    }) }
    val voiceConversation = com.henrydashwood.magpie.voice.Conversation(store = conversationStore)
    val voiceHandoffs = com.henrydashwood.magpie.voice.VoiceHandoffs()
    data class SpeedUndo(val owner: String?, val revision: Int, val kind: ContentKind,
        val before: Float, val after: Float, val expiresAt: Long)
    var speedUndo: SpeedUndo? = null
    val actions = LibraryActionExecution(voiceConversation, { state.value.owner }) {
        state.value.takeIf { it.live && it.owner != null }?.let { "${it.revision}:${it.owner}:${it.live}" }
    }

    fun libraryAction(action: String, episodeId: Int?, requestId: String, sessionRevision: Int): com.henrydashwood.magpie.voice.VoiceOperation {
        val (current, version) = credentials()
        check(sessionRevision)
        val actions = checkNotNull(api as? LibraryActionApi) { "Library actions are unavailable." }
        return object : com.henrydashwood.magpie.voice.VoiceOperation {
            override suspend fun response(onDelta: (String) -> Unit): com.henrydashwood.magpie.voice.VoiceResponse {
                check(version)
                val response = actions.libraryAction(current, action, episodeId, requestId)
                check(version)
                com.henrydashwood.magpie.voice.StructuredLibraryRequest(action, episodeId).validate(response)
                return response
            }
            override suspend fun cancel() = actions.cancelLibraryAction(current, requestId)
        }
    }

    private fun preview() = SampleLibrary().items.let { items -> LibraryState(revision = revision, items = items,
        latestIds = items.map { it.id }, feeds = items.groupBy { it.source }.map { (source, stories) ->
            LibraryFeed(source, source, stories.size, stories.all { it.kind == ContentKind.Article })
        }) }

    suspend fun changeSession(value: String?) {
        if (value == token) {
            if (value == null) runCatching { telemetry?.clear() }
            return
        }
        val previousOwner = state.value.owner
        token = value
        revision++
        telemetry?.invalidate()
        val version = revision
        actions.invalidate()
        voiceConversation.activate(null)
        voiceHandoffs.clear()
        speedUndo = null
        searchVersion++
        mutable.value = if (value == null) preview() else LibraryState(live = true, revision = revision, loading = true,
            owner = identityStore?.owner(digest(server + ":" + value)))
        if (value == null) try { telemetry?.clear() }
        catch (cancelled: CancellationException) { throw cancelled }
        catch (_: Exception) { /* Failure to remove diagnostics cannot block signing out. */ }
        if (value == null && previousOwner != null) {
            cacheWrites.withLock { cache?.clear(previousOwner) }
            progressQueue?.clear(previousOwner)
            articleQueue?.clear(previousOwner)
            voiceConversation.clearStored(previousOwner)
        }
        check(version)
        if (value != null) {
            state.value.owner?.let { owner -> writes.withLock { check(version); restoreCache(owner, version); overlayProgress(owner, version, false) } }
            check(version)
            refresh()
            telemetry?.flush()
        }
    }
    private fun check(version: Int) { if (version != revision) throw CancellationException("Account changed") }
    private fun credentials() = checkNotNull(token) { "Sign in to use your library." } to revision

    private suspend fun restoreCache(owner: String, version: Int) {
        val restored = try { cache?.load(owner)?.takeIf { it.owner == owner }?.restore(version) }
            catch (cancelled: CancellationException) { throw cancelled }
            catch (_: Exception) { null }
        check(version)
        if (restored != null) {
            // Restoration shares the write lock with refresh/mutations. A read-only
            // search may finish meanwhile; retain its current results and preserve
            // the cached Saved content selection until a live refresh replaces it.
            val current = state.value
            mutable.value = restored.copy(items = merge(restored.items, current.items.filterNot { it.id in restored.savedIds }),
                feedItems = restored.feedItems + current.feedItems, feedResults = current.feedResults,
                searchResults = current.searchResults, searching = current.searching, error = current.error)
        }
    }

    /** A cache failure cannot turn an accepted server write into a failed mutation. */
    private suspend fun checkpoint(version: Int = revision) {
        if (cache == null) return
        cacheWrites.withLock {
            check(version)
            val snapshot = state.value.takeIf { it.live && it.owner != null } ?: return@withLock
            try { cache.save(LibrarySnapshot.from(snapshot)) }
            catch (cancelled: CancellationException) { throw cancelled }
            catch (_: Exception) {
                check(version)
                mutable.value = state.value.copy(error = "Your library is up to date, but it could not be saved for offline use.")
            }
            check(version)
        }
    }

    suspend fun refresh() {
        val (current, version) = credentials()
        writes.withLock {
            check(version)
            mutable.value = state.value.copy(loading = true, error = null)
            try {
                val owner = state.value.owner ?: digest(server + ":" + api.userId(current))
                check(version)
                identityStore?.remember(digest(server + ":" + current), owner)
                check(version)
                if (state.value.owner == null) { restoreCache(owner, version); overlayProgress(owner, version, false) }
                mutable.value = state.value.copy(owner = owner)
                val result = coroutineScope {
                    val feeds = async { api.feeds(current) }
                    val latest = async { api.latest(current) }
                    val saved = async { api.saved(current) }
                    Triple(feeds.await(), latest.await(), saved.await())
                }
                check(version)
                val next = state.value.copy(owner = owner, feeds = result.first)
                val latest = result.second.map { it.item(next) }
                val saved = result.third.map { it.item(next) }
                mutable.value = next.copy(items = merge(next.items, latest + saved), latestIds = latest.map { it.id },
                    savedIds = saved.map { it.id }, loading = false)
                overlayProgress(owner, version, true)
                checkpoint(version)
            } catch (cancelled: CancellationException) {
                // A cancelled reconciliation must not leave future assistant
                // requests waiting forever for a refresh that no longer exists.
                if (state.value.revision == version) mutable.value = state.value.copy(loading = false)
                throw cancelled
            } catch (failure: Exception) {
                check(version)
                mutable.value = state.value.copy(loading = false, error = message(failure))
            }
        }
    }

    suspend fun search(feedId: String?, query: String) {
        val (current, version) = credentials()
        val request = ++searchVersion
        if (feedId == null && query.isBlank()) {
            // Returning to Following performs no request and must retain a failed
            // initial-load error, including when only the cached account is known.
            mutable.value = state.value.copy(searching = false, feedResults = emptyList(), searchResults = emptyList())
            return
        }
        val cached = offlineResults(feedId, query)
        mutable.value = state.value.copy(searching = true, error = null,
            feedResults = if (feedId != null) cached else emptyList(),
            searchResults = if (feedId == null) cached else emptyList())
        try {
            val rows = if (feedId != null) api.episodes(current, feedId, query)
                else if (query.isBlank()) emptyList() else api.search(current, query)
            check(version)
            if (request != searchVersion) return
            val items = rows.map { row -> state.value.items.firstOrNull { it.episodeId == row.id && it.id in state.value.savedIds } ?: row.item(state.value) }
            mutable.value = state.value.copy(items = merge(state.value.items, items), searching = false,
                feedResults = if (feedId != null) items.map { it.id } else emptyList(),
                searchResults = if (feedId == null) items.map { it.id } else emptyList(),
                feedItems = if (feedId != null && query.isBlank()) state.value.feedItems + (feedId to items.map { it.id }) else state.value.feedItems)
            checkpoint(version)
        } catch (cancelled: CancellationException) { throw cancelled
        } catch (failure: Exception) {
            check(version)
            if (request == searchVersion) mutable.value = state.value.copy(searching = false, error =
                if (failure is IOException && cached.isNotEmpty()) "Could not refresh. Showing items already on this device." else message(failure))
        }
    }

    private fun offlineResults(feedId: String?, query: String): List<String> {
        val snapshot = state.value
        val ids = if (feedId != null) snapshot.feedItems[feedId].orEmpty() else snapshot.items.map { it.id }
        val items = snapshot.items.associateBy { it.id }
        return ids.filter { id -> items[id]?.let { item ->
            query.isBlank() || "${item.title} ${item.source} ${item.description}".contains(query, ignoreCase = true)
        } == true }
    }

    /** Resolve a shortcut against the current account, including items outside Latest/Saved. */
    suspend fun shortcutItem(id: String): LibraryItem {
        if (!state.value.live) return state.value.items.firstOrNull { it.id == id }
            ?: throw IllegalArgumentException("That sample is no longer available.")
        val (current, version) = credentials()
        val prefix = "${checkNotNull(state.value.owner)}:episode:"
        require(id.startsWith(prefix)) { "This shortcut belongs to another account." }
        val episodeId = id.removePrefix(prefix).toIntOrNull()?.takeIf { it > 0 }
            ?: throw IllegalArgumentException("That shortcut is no longer available.")
        return writes.withLock {
            check(version)
            val row = try { api.episode(current, episodeId) } catch (failure: IOException) {
                check(version)
                return@withLock state.value.items.firstOrNull { it.id == id } ?: throw failure
            }
            check(version)
            require(row.id == episodeId) { "The requested item could not be found." }
            acceptEpisode(row, version)
        }
    }

    /** Fresh read-only results without replacing the search currently displayed in the app. */
    suspend fun shortcutItems(feedId: String? = null, query: String = "", savedOnly: Boolean = false, limit: Int? = null): List<LibraryItem> {
        require(query.length <= 200 && !(savedOnly && feedId != null)) { "Choose a shorter library search." }
        require(limit == null || limit in 1..100 && !savedOnly) { "Choose between one and 100 results." }
        if (!state.value.live) return state.value.items.filter { (feedId == null || it.sourceId == feedId) &&
            (query.isBlank() || "${it.title} ${it.source} ${it.description}".contains(query, ignoreCase = true)) }.take(limit ?: Int.MAX_VALUE)
        val (current, version) = credentials()
        return writes.withLock {
            check(version)
            if (feedId != null) require(state.value.feeds.any { it.id == feedId }) { "That show is no longer followed." }
            val rows = when {
                savedOnly -> api.saved(current)
                limit != null -> api.find(current, feedId, query, limit)
                feedId != null -> api.episodes(current, feedId, query)
                query.isNotBlank() -> api.search(current, query)
                else -> api.latest(current)
            }
            check(version)
            val items = rows.map { it.item(state.value) }
            mutable.value = state.value.copy(items = merge(state.value.items, items))
            val result = items.map { row -> state.value.items.first { it.id == row.id } }
            checkpoint(version)
            result
        }
    }

    suspend fun content(id: String, forPlayback: Boolean = false): LibraryItem {
        val (current, version) = credentials()
        var item = state.value.items.first { it.id == id }
        val refreshProgress = forPlayback && api is ArticleProgressApi
        if (item.kind == ContentKind.Podcast || (item.textLoaded && !refreshProgress)) return item
        val cached = item
        val mutation = progressMutation
        return try {
            // Explicit playback resolves the account's current selection/bookmark even
            // when its text is already cached. A running player's baseline stays fixed.
            if (refreshProgress) {
                val row = api.episode(current, checkNotNull(item.episodeId))
                check(version)
                item = merge(listOf(item), listOf(row.item(state.value))).single()
            }
            val text = api.text(current, checkNotNull(item.episodeId), item.contentId)
            check(version)
            require(text.episodeId == item.episodeId && (item.contentId == null || text.contentId == item.contentId)) {
                "The article version changed. Refresh your library and try again."
            }
            require(text.text.isNotBlank()) { "The article has no readable text yet." }
            val textVersion = digest(text.text)
            require(text.articleProgress == null || (text.articleProgress.textVersion == textVersion && text.articleProgress.contentId == text.contentId))
            val loaded = item.copy(text = text.text, html = text.html, wordCount = text.wordCount,
                contentVersion = textVersion, textLoaded = true, contentId = text.contentId,
                articleProgress = text.articleProgress, articleBookmark = if (text.articleProgress != null) text.articleProgress.bookmark else item.articleBookmark)
            writes.withLock {
                check(version)
                val now = state.value.items.firstOrNull { it.id == id }
                if (mutation != progressMutation || now == null || now.contentId != cached.contentId || now.articleBookmark != cached.articleBookmark ||
                    now.completed != cached.completed || now.dismissed != cached.dismissed)
                    throw CancellationException("Article changed")
                mutable.value = state.value.copy(items = merge(state.value.items, listOf(loaded)))
                overlayArticleProgress(checkNotNull(state.value.owner), version, true)
                checkpoint(version)
                state.value.items.first { it.id == id }
            }
        } catch (failure: IOException) {
            check(version)
            if (!cached.textLoaded || state.value.items.firstOrNull { it.id == id } != cached) throw failure
            // Do not combine newly fetched metadata with older cached text when a
            // connection disappears between fetching the selection and its text.
            cached
        }
    }

    suspend fun save(item: LibraryItem? = null, url: String? = null) = mutate { current ->
        if (item != null) requireItem(item)
        val row = api.save(current, item?.episodeId, url);
        { val added = row.item(state.value)
            mutable.value = state.value.copy(items = merge(state.value.items, listOf(added)), savedIds = (listOf(added.id) + state.value.savedIds).distinct()) }
    }
    suspend fun remove(item: LibraryItem) = mutate { current ->
        requireItem(item)
        api.remove(current, checkNotNull(item.episodeId));
        { mutable.value = state.value.copy(savedIds = state.value.savedIds - item.id) }
    }
    suspend fun played(item: LibraryItem, value: Boolean) = mutate { current ->
        requireItem(item)
        if (item.kind == ContentKind.Article && state.value.items.first { it.id == item.id }.contentId != item.contentId)
            throw CancellationException("Article changed")
        blockProgress(setOf(checkNotNull(item.episodeId)))
        api.played(current, checkNotNull(item.episodeId), value);
        { mutable.value = state.value.copy(items = state.value.items.map { if (it.id == item.id) it.copy(completed = value) else it },
            latestIds = if (value) state.value.latestIds - item.id else state.value.latestIds) }
    }
    suspend fun clearLatest() = mutate { current ->
        api.clearLatest(current);
        { mutable.value = state.value.copy(latestIds = emptyList()) }
    }
    suspend fun subscribe(url: String) = mutate { current ->
        val feed = api.subscribe(current, url);
        { mutable.value = state.value.copy(feeds = (state.value.feeds.filterNot { it.id == feed.id } + feed).sortedBy { it.title.lowercase() }); feed }
    }
    /** Rediscover choices before writing; IDs bind the website, account and session. */
    suspend fun followPublication(url: String, choiceId: String? = null): PublicationFollow {
        val version = state.value.revision
        val owner = checkNotNull(state.value.owner) { "Open Magpie and sign in first." }
        val website = validateLink(url)
        val choices = discoverSources(website).map { candidate ->
            val feedUrl = validateLink(candidate.url)
            PublicationChoice(digest("$owner:$version:$website:$feedUrl"), candidate.title, feedUrl)
        }.distinctBy { it.url }
        check(version)
        require(choices.isNotEmpty()) { "I could not find a feed at that address." }
        val chosen = if (choiceId != null) choices.firstOrNull { it.id == choiceId }
            ?: throw IllegalArgumentException("That feed choice is no longer available. Discover the address again.")
        else choices.singleOrNull() ?: return PublicationFollow(null, choices)
        state.value.feeds.firstOrNull { it.url == chosen.url }?.let { return PublicationFollow(it, alreadyFollowed = true) }
        val feed = try { subscribe(chosen.url) }
        catch (failure: AccountFailure) {
            if (failure.status != 409) throw failure
            // The first reply may have been lost, or another device followed it.
            // Preview resolves redirects to the canonical feed ID without writing.
            val preview = previewSource(chosen.url)
            check(version)
            refresh(); check(version)
            val existing = state.value.feeds.firstOrNull { it.id == preview.feed.id || it.url == chosen.url } ?: throw failure
            return PublicationFollow(existing, alreadyFollowed = true)
        }
        check(version)
        speedUndo = null
        refresh(); check(version)
        return PublicationFollow(feed)
    }
    private suspend fun <T> discovery(work: suspend (DiscoveryApi, String) -> T): T {
        val (current, version) = credentials()
        val result = work(checkNotNull(api as? DiscoveryApi) { "Source discovery is unavailable." }, current)
        check(version)
        return result
    }
    private suspend fun <T> newsletter(work: suspend (NewsletterApi, String) -> T): T {
        val (current, version) = credentials()
        val result = work(checkNotNull(api as? NewsletterApi) { "Newsletters are unavailable." }, current)
        check(version)
        return result
    }
    override suspend fun newsletterAddress() = newsletter { source, current -> source.newsletterAddress(current) }
    override suspend fun pendingNewsletters(): List<PendingNewsletter> {
        val version = revision
        return newsletter { source, current -> source.pendingNewsletters(current) }.map { it.copy(sessionRevision = version) }
    }
    override suspend fun approveNewsletter(item: PendingNewsletter) {
        check(item.sessionRevision)
        require(item.id > 0)
        mutate { current ->
            val feed = checkNotNull(api as? NewsletterApi).approveNewsletter(current, item.id);
            { mutable.value = state.value.copy(feeds = (state.value.feeds.filterNot { it.id == feed.id } + feed).sortedBy { it.title.lowercase() }) }
        }
        check(item.sessionRevision)
        refresh()
        check(item.sessionRevision)
    }
    override suspend fun blockNewsletter(item: PendingNewsletter) {
        check(item.sessionRevision)
        require(item.id > 0)
        mutate { current ->
            checkNotNull(api as? NewsletterApi).blockNewsletter(current, item.id);
            { }
        }
    }
    override suspend fun signUpForNewsletter(url: String) = newsletter { source, current -> source.signUpForNewsletter(current, validateLink(url)) }
    private suspend fun acceptEpisodes(rows: List<RemoteEpisode>): List<String> {
        val (current, version) = credentials()
        val owner = state.value.owner ?: digest(server + ":" + api.userId(current))
        check(version)
        val next = state.value.copy(owner = owner)
        // Saved articles retain their selected immutable content version.
        val items = rows.map { row -> next.items.firstOrNull { it.episodeId == row.id && it.id in next.savedIds } ?: row.item(next) }
        mutable.value = next.copy(items = merge(next.items, items))
        checkpoint(version)
        return items.map { it.id }
    }
    override suspend fun findSources(query: String): SourceMatches = discovery { sourceApi, current ->
        coroutineScope {
            suspend fun <T> attempt(block: suspend () -> T): Result<T> = try { Result.success(block()) }
                catch (cancelled: CancellationException) { throw cancelled } catch (failure: Exception) { Result.failure(failure) }
            val directory = async { attempt { sourceApi.directory(current, query) } }
            val episodes = async { attempt { api.search(current, query) } }
            directory.await() to episodes.await()
        }
    }.let { (sources, rows) ->
        SourceMatches(sources.getOrDefault(emptyList()), acceptEpisodes(rows.getOrDefault(emptyList())),
            listOfNotNull(sources.exceptionOrNull(), rows.exceptionOrNull()).map { message(it as Exception) }.distinct().joinToString(" ").ifBlank { null })
    }
    override suspend fun discoverSources(url: String) = discovery { sourceApi, current -> sourceApi.discover(current, validateLink(url)).distinctBy { it.url } }
    override suspend fun previewSource(url: String): SourcePreview {
        val preview = discovery { sourceApi, current -> sourceApi.preview(current, validateLink(url)) }
        return SourcePreview(preview.feed, acceptEpisodes(preview.episodes), preview.subscribed, state.value.revision)
    }
    override suspend fun followSource(preview: SourcePreview): SourcePreview {
        require(preview.sessionRevision == state.value.revision) { "This preview belongs to a different session." }
        try { subscribe(checkNotNull(preview.feed.url)) }
        catch (failure: AccountFailure) {
            if (failure.status != 409) throw failure
            // Another device may have subscribed since this preview was loaded.
            refresh()
            if (state.value.feeds.none { it.id == preview.feed.id || it.url == preview.feed.url }) throw failure
        }
        return preview.copy(subscribed = true)
    }
    override suspend fun findPublication(query: String) = discovery { sourceApi, current -> sourceApi.webSearch(current, query) }
    override suspend fun aiConsent() = discovery { sourceApi, current -> sourceApi.aiConsent(current) }
    override suspend fun setAIConsent(granted: Boolean) = discovery { sourceApi, current -> sourceApi.setAIConsent(current, granted) }
    override suspend fun sourceGroup(feedId: String, sessionRevision: Int): SourceGroup {
        val (current, version) = credentials()
        check(sessionRevision)
        return writes.withLock {
            check(version)
            val management = checkNotNull(api as? SourceManagementApi)
            val result = coroutineScope {
                val sources = async { management.feedSources(current, feedId) }
                val feeds = async { api.feeds(current) }
                sources.await() to feeds.await()
            }
            check(version)
            SourceGroup(result.first.sortedByDescending { it.primary },
                result.second.filter { it.id != feedId && result.first.none { source -> source.id == it.id } })
        }
    }
    override suspend fun changeSourceGroup(feedId: String, sourceId: String?, change: SourceChange, sessionRevision: Int) {
        val (current, version) = credentials()
        check(sessionRevision)
        writes.withLock {
            check(version)
            require(feedId != sourceId) { "The primary source cannot be separated or combined with itself." }
            checkNotNull(api as? SourceManagementApi).changeSources(current, feedId, sourceId, change)
            check(version)
            // Invalidate replies from the previous grouping. Keep item/text caches
            // and bookmarks so Saved and current playback survive unsubscribing.
            searchVersion++
            val removedId = when (change) {
                SourceChange.Combine -> sourceId
                SourceChange.Unsubscribe -> feedId
                SourceChange.Separate -> null
            }
            mutable.value = state.value.copy(feeds = state.value.feeds.filterNot { it.id == removedId },
                catalogRevision = state.value.catalogRevision + 1, feedResults = emptyList(), searchResults = emptyList(),
                latestIds = emptyList(), searching = false, feedItems = emptyMap())
            checkpoint(version)
        }
        // A failed refresh is reported as a library refresh error, not a failed
        // write. The server has already accepted the source change.
        refresh()
    }
    override suspend fun unfollowSource(preview: SourcePreview): SourcePreview {
        changeSourceGroup(preview.feed.id, null, SourceChange.Unsubscribe, preview.sessionRevision)
        return preview.copy(subscribed = false)
    }
    override suspend fun captureSaved(article: PendingArticle, revision: Int) {
        val (current, version) = credentials()
        check(revision)
        writes.withLock {
            check(version)
            val row = checkNotNull(api as? SavedArticleApi).capture(current, article)
            check(version)
            acceptSaved(row)
        }
    }
    override suspend fun prepareSaved(item: LibraryItem, replace: Boolean, revision: Int): LibraryItem {
        val (current, version) = credentials()
        check(revision)
        return writes.withLock {
            check(version)
            require(item.id in state.value.savedIds && item.kind == ContentKind.Article) { "This article is no longer in Saved." }
            val savedApi = checkNotNull(api as? SavedArticleApi)
            val row = if (replace) savedApi.replaceSaved(current, checkNotNull(item.episodeId)) else savedApi.retrySaved(current, checkNotNull(item.episodeId))
            check(version)
            require(row.id == item.episodeId) { "The saved article changed. Refresh and try again." }
            acceptSaved(row)
        }
    }
    private suspend fun acceptSaved(row: RemoteEpisode): LibraryItem {
        // A search started before replacement must not restore the old selection.
        searchVersion++
        val added = row.item(state.value)
        val items = merge(state.value.items, listOf(added))
        val savedIds = if (added.id in state.value.savedIds) state.value.savedIds else listOf(added.id) + state.value.savedIds
        mutable.value = state.value.copy(items = items, savedIds = savedIds, searching = false)
        checkpoint()
        return items.first { it.id == added.id }
    }
    fun voiceOperation(request: com.henrydashwood.magpie.voice.VoiceRequest, sessionRevision: Int): com.henrydashwood.magpie.voice.VoiceOperation {
        voiceConversation.structured(request.requestId)?.let {
            return libraryAction(it.action, it.episodeId, request.requestId, sessionRevision)
        }
        val (current, version) = credentials()
        check(sessionRevision)
        val voice = checkNotNull(api as? com.henrydashwood.magpie.voice.VoiceApi) { "Voice commands are unavailable." }
        return object : com.henrydashwood.magpie.voice.VoiceOperation {
            override suspend fun response(onDelta: (String) -> Unit): com.henrydashwood.magpie.voice.VoiceResponse {
                check(version)
                val response = com.henrydashwood.magpie.voice.VoiceExecution.response(voice.events(current, request)) {
                    check(version); onDelta(it)
                }
                check(version)
                return response
            }
            override suspend fun cancel() {
                // Cancel only this request using its original account. Never route an old
                // operation's cancellation through a newly signed-in account's token.
                voice.cancel(current, request.requestId)
            }
        }
    }
    // Finish any older refresh before adopting a confirmed receipt. Otherwise an omitted
    // filed item can retain an older unplayed snapshot even after the follow-up refresh.
    suspend fun acceptVoiceEpisode(row: RemoteEpisode, sessionRevision: Int): LibraryItem = writes.withLock {
        progressMutation++
        acceptEpisode(row, sessionRevision)
    }
    private suspend fun acceptEpisode(row: RemoteEpisode, sessionRevision: Int): LibraryItem {
        check(sessionRevision)
        require(state.value.live && row.id > 0)
        val item = row.item(state.value)
        mutable.value = state.value.copy(items = merge(state.value.items, listOf(item)))
        checkpoint(sessionRevision)
        return state.value.items.first { it.id == item.id }
    }
    private fun requireItem(item: LibraryItem) { require(state.value.items.any { it.id == item.id }) { "This item belongs to a different library." } }
    private suspend fun <T> mutate(work: suspend (String) -> (() -> T)): T {
        val (current, version) = credentials()
        return writes.withLock {
            check(version)
            val commit = work(current)
            check(version)
            val result = commit()
            progressMutation++
            checkpoint(version)
            result
        }
    }
    suspend fun recoverVoiceEpisode(episodeId: Int, sessionRevision: Int) {
        val (current, version) = credentials()
        check(sessionRevision)
        val episode = api.episode(current, episodeId)
        check(version)
        acceptVoiceEpisode(episode, version)
    }

    fun usesGuardedProgress(item: LibraryItem) = when (item.kind) {
        ContentKind.Podcast -> progressQueue != null && api is PodcastProgressApi && item.progressRevision != null
        ContentKind.Article -> articleQueue != null && api is ArticleProgressApi && item.articleProgress?.let {
            item.textLoaded && it.textVersion == item.contentVersion && it.contentId == item.contentId
        } == true
    }

    suspend fun beginArticleProgress(item: LibraryItem, playbackId: String, offset: Int) {
        val version = revision
        requireItem(item)
        if (!usesGuardedProgress(item)) return
        val progress = checkNotNull(item.articleProgress)
        articleQueue!!.start(checkNotNull(state.value.owner), checkNotNull(item.episodeId), playbackId, progress.revision,
            ArticleProgressSample(progress.textVersion, progress.contentId, offset), item.dismissed) { version == revision }
    }
    suspend fun recordArticleProgress(item: LibraryItem, playbackId: String, offset: Int, completed: Boolean): Boolean {
        val version = revision
        requireItem(item)
        val owner = checkNotNull(state.value.owner)
        val recorded = articleQueue?.record(owner, checkNotNull(item.episodeId), playbackId,
            ArticleProgressSample(item.contentVersion, item.contentId, offset, completed)) { version == revision } ?: false
        check(version)
        if (recorded) overlayArticleProgress(owner, version, true)
        return recorded
    }

    suspend fun beginPodcastProgress(item: LibraryItem, playbackId: String, seconds: Double) {
        val version = revision
        requireItem(item)
        if (!usesGuardedProgress(item)) return
        progressQueue!!.start(checkNotNull(state.value.owner), checkNotNull(item.episodeId), playbackId,
            checkNotNull(item.progressRevision), ProgressSample(seconds), item.dismissed) { version == revision }
    }
    suspend fun recordPodcastProgress(item: LibraryItem, playbackId: String, seconds: Double, completed: Boolean): Boolean {
        val version = revision
        requireItem(item)
        val owner = checkNotNull(state.value.owner)
        val recorded = progressQueue?.record(owner, checkNotNull(item.episodeId), playbackId,
            ProgressSample(seconds, completed)) { version == revision } ?: false
        check(version)
        if (recorded) overlayProgress(owner, version, true)
        return recorded
    }
    suspend fun holdProgress(episodeIds: Set<Int>, requestId: String) {
        val version = revision
        val owner = state.value.owner ?: return
        progressQueue?.hold(owner, episodeIds, requestId) { version == revision }
        articleQueue?.hold(owner, episodeIds, requestId) { version == revision }
    }
    suspend fun confirmProgress(requestId: String) {
        val version = revision
        val owner = state.value.owner ?: return
        progressQueue?.confirm(owner, requestId) { version == revision }
        articleQueue?.confirm(owner, requestId) { version == revision }
    }
    suspend fun blockProgress(episodeIds: Set<Int>) {
        val version = revision
        val owner = state.value.owner ?: return
        progressQueue?.block(owner, episodeIds) { version == revision }
        articleQueue?.block(owner, episodeIds) { version == revision }
    }
    suspend fun awaitProgress() { progressQueue?.awaitNetwork(); articleQueue?.awaitNetwork() }

    private suspend fun overlayProgress(owner: String, version: Int, fresh: Boolean) {
        overlayArticleProgress(owner, version, fresh)
        val entries = try { progressQueue?.entries(owner) ?: return }
        catch (cancelled: CancellationException) { throw cancelled }
        catch (_: Exception) {
            check(version)
            mutable.value = state.value.copy(error = "Saved listening progress could not be read. Your library is still available.")
            return
        }
        check(version)
        val byId = entries.filter { !it.blocked && it.guards.isEmpty() && it.sampled }.associateBy { it.episodeId }
        val items = state.value.items.map { item ->
            val entry = byId[item.episodeId]
            if (entry == null || (fresh && item.progressRevision != entry.baselineRevision)) item
            else item.copy(remotePositionMs = if (entry.latest.completed) 0 else (entry.latest.seconds * 1000).toLong(),
                completed = entry.latest.completed, dismissed = entry.dismissed, progressRevision = entry.baselineRevision)
        }
        mutable.value = state.value.copy(items = items,
            latestIds = state.value.latestIds.filter { id -> items.none { it.id == id && (it.completed || it.dismissed) } })
    }

    private suspend fun overlayArticleProgress(owner: String, version: Int, fresh: Boolean) {
        val entries = try { articleQueue?.entries(owner) ?: return }
        catch (cancelled: CancellationException) { throw cancelled }
        catch (_: Exception) {
            check(version)
            mutable.value = state.value.copy(error = "Saved article progress could not be read. Your library is still available.")
            return
        }
        check(version)
        val byId = entries.filter { !it.blocked && it.guards.isEmpty() && it.sampled }.associateBy { it.episodeId }
        val items = state.value.items.map { item ->
            val entry = byId[item.episodeId]
            if (entry == null || entry.latest.textVersion != item.contentVersion || entry.latest.contentId != item.contentId ||
                (fresh && item.articleProgress?.revision != entry.baselineRevision)) item
            else {
                val bookmark = RemoteArticleBookmark(entry.latest.textVersion, entry.latest.offsetUtf16)
                item.copy(articleBookmark = bookmark, articleProgress = item.articleProgress?.copy(bookmark = bookmark),
                    completed = entry.latest.completed, dismissed = entry.dismissed)
            }
        }
        mutable.value = state.value.copy(items = items,
            latestIds = state.value.latestIds.filter { id -> items.none { it.id == id && (it.completed || it.dismissed) } })
    }

    suspend fun flushProgress() {
        // A failed podcast request must not starve unrelated article progress.
        var failed: Exception? = null
        try { flushPodcastProgress() }
        catch (cancelled: CancellationException) { throw cancelled }
        catch (failure: Exception) { failed = failure }
        flushArticleProgress()
        failed?.let { throw it }
    }
    suspend fun flushArticleProgress() {
        val queue = articleQueue ?: return
        val progressApi = api as? ArticleProgressApi ?: return
        if (!state.value.live || state.value.owner == null) return
        val (current, version) = credentials()
        val owner = checkNotNull(state.value.owner)
        var observed: LibraryItem? = null
        var mutation = progressMutation
        queue.flush(owner, { version == revision }, send = { id, report ->
            observed = state.value.items.firstOrNull { it.episodeId == id }
            mutation = progressMutation
            try { progressApi.articleProgress(current, id, report) }
            catch (failure: AccountFailure) {
                check(version)
                if (failure.status == 409) {
                    val row = api.episode(current, id)
                    val text = api.text(current, id, row.contentId)
                    check(version)
                    val progress = text.articleProgress
                    if (progress != null) throw ArticleProgressConflict(row, progress)
                    queue.block(owner, setOf(id)) { version == revision }
                }
                if (failure.status in setOf(403, 404, 422)) queue.block(owner, setOf(id)) { version == revision }
                throw failure
            }
        }, applied = { row, progress, changed ->
            check(version)
            if (mutation == progressMutation && state.value.items.firstOrNull { it.episodeId == row.id }?.articleProgress?.revision == observed?.articleProgress?.revision) {
                val item = row.item(state.value)
                val merged = merge(state.value.items, listOf(item)).map {
                    if (it.id == item.id && it.contentVersion == progress.textVersion && it.contentId == progress.contentId)
                        it.copy(articleProgress = progress, articleBookmark = progress.bookmark) else it
                }
                mutable.value = state.value.copy(items = merged,
                    latestIds = if (item.completed || item.dismissed) state.value.latestIds - item.id else state.value.latestIds)
                overlayArticleProgress(owner, version, true)
                checkpoint(version)
            }
            if (changed) mutable.value = state.value.copy(error = "This article changed on another device. Its newer progress was kept. Choose Play again to continue here.")
        })
    }

    suspend fun flushPodcastProgress() {
        val queue = progressQueue ?: return
        val progressApi = api as? PodcastProgressApi ?: return
        if (!state.value.live || state.value.owner == null) return
        val (current, version) = credentials()
        val owner = checkNotNull(state.value.owner)
        var observed: LibraryItem? = null
        var mutation = progressMutation
        queue.flush(owner, { version == revision }, send = { id, report ->
            observed = state.value.items.firstOrNull { it.episodeId == id }
            mutation = progressMutation
            try {
                // A missing/corrupt content cache must not strand the journal.
                // Fetch capability without rebasing the original queued request.
                val supported = observed?.progressRevision ?: api.episode(current, id).progressRevision
                check(version)
                check(supported != null) { "Progress is waiting for a compatible Magpie connection." }
                progressApi.podcastProgress(current, id, report)
            } catch (failure: AccountFailure) {
                check(version)
                if (failure.status == 409) throw ProgressConflict(api.episode(current, id))
                if (failure.status in setOf(403, 404, 422)) queue.block(owner, setOf(id)) { version == revision }
                throw failure
            }
        }, applied = { row, changed ->
            check(version)
            if (mutation == progressMutation && state.value.items.firstOrNull { it.episodeId == row.id }?.progressRevision == observed?.progressRevision) {
                val item = row.item(state.value)
                mutable.value = state.value.copy(items = merge(state.value.items, listOf(item)),
                    latestIds = if (item.completed || item.dismissed) state.value.latestIds - item.id else state.value.latestIds)
                overlayProgress(owner, version, true)
                checkpoint(version)
            }
            if (changed) mutable.value = state.value.copy(error = "This item changed on another device. Its newer progress was kept. Choose Play again to continue here.")
        })
    }
    suspend fun reportPodcast(item: LibraryItem, seconds: Double, completed: Boolean) {
        val (current, version) = credentials()
        require(item.kind == ContentKind.Podcast && state.value.items.any { it.id == item.id })
        api.position(current, checkNotNull(item.episodeId), seconds, completed)
        check(version)
        mutable.value = state.value.copy(items = state.value.items.map {
            if (it.id == item.id) it.copy(remotePositionMs = if (completed) 0 else (seconds * 1000).toLong(), completed = completed || it.completed) else it
        })
    }
    private fun RemoteEpisode.item(state: LibraryState): LibraryItem {
        val podcast = audioUrl != null
        return LibraryItem("${checkNotNull(state.owner)}:episode:$id", source, title, description,
            if (podcast) ContentKind.Podcast else ContentKind.Article,
            durationSeconds?.let { "${(it / 60).coerceAtLeast(1)} min" } ?: if (podcast) "Podcast" else "Article",
            if (podcast) description else "", contentVersion = "unloaded:$contentId", originalUrl = link,
            episodeId = id, contentId = contentId, sourceId = state.feeds.firstOrNull { feedUrl != null && it.url == feedUrl }?.id ?: feedUrl ?: source,
            audioUrl = audioUrl, wordCount = wordCount, textLoaded = podcast,
            remotePositionMs = if (completed) 0 else (positionSeconds * 1000).toLong().coerceAtLeast(0),
            completed = completed, dismissed = dismissed, captureError = captureError,
            durationSeconds = durationSeconds?.takeIf { it > 0 }, progressRevision = progressRevision, articleBookmark = articleBookmark, publishedAt = publishedAt, imageUrl = imageUrl)
    }
    private fun merge(existing: List<LibraryItem>, rows: List<LibraryItem>): List<LibraryItem> {
        val items = existing.associateBy { it.id }.toMutableMap()
        for (row in rows) {
            val old = items[row.id]
            items[row.id] = if (old?.textLoaded == true && !row.textLoaded && old.contentId == row.contentId)
                row.copy(text = old.text, html = old.html, textLoaded = true, contentVersion = old.contentVersion, wordCount = row.wordCount ?: old.wordCount,
                    articleProgress = old.articleProgress?.takeIf { old.articleBookmark == row.articleBookmark &&
                        old.completed == row.completed && old.dismissed == row.dismissed && old.remotePositionMs == row.remotePositionMs }) else row
        }
        return items.values.toList()
    }
    companion object {
        fun message(failure: Exception): String = when (failure) {
            is AccountFailure -> failure.message
            is IOException -> "Could not connect to Magpie. Check your connection and try again."
            is IllegalArgumentException -> failure.message ?: "This item could not be opened. Refresh your library and try again."
            else -> "Your library could not be loaded. Please try again."
        }
        private fun digest(value: String) = MessageDigest.getInstance("SHA-256").digest(value.toByteArray()).joinToString("") { "%02x".format(it) }
    }
}
