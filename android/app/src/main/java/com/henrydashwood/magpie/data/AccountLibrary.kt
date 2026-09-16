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
    val feedResults: List<String> = emptyList(), val searchResults: List<String> = emptyList(),
    val loading: Boolean = false, val searching: Boolean = false, val error: String? = null)

/** Main-dispatcher state. Every result is bound to the initiating session revision.
 * Account data is kept in memory; a failed load never falls back to sample data. */
class AccountLibrary(private val api: LibraryApi, private val server: String, initiallySignedIn: Boolean = false,
    private val identityStore: AccountIdentityStore? = null) : SourceRepository, SourceManagementRepository, SavedArticleRepository {
    private var token: String? = null
    private var revision = 0
    private var searchVersion = 0
    private val writes = Mutex()
    private val mutable = MutableStateFlow(if (initiallySignedIn) LibraryState(live = true, loading = true) else preview())
    val state = mutable.asStateFlow()

    private fun preview() = SampleLibrary().items.let { items -> LibraryState(revision = revision, items = items,
        latestIds = items.map { it.id }, feeds = items.groupBy { it.source }.map { (source, stories) ->
            LibraryFeed(source, source, stories.size, stories.all { it.kind == ContentKind.Article })
        }) }

    suspend fun changeSession(value: String?) {
        if (value == token) return
        token = value
        revision++
        searchVersion++
        mutable.value = if (value == null) preview() else LibraryState(live = true, revision = revision, loading = true,
            owner = identityStore?.owner(digest(server + ":" + value)))
        if (value != null) refresh()
    }
    private fun check(version: Int) { if (version != revision) throw CancellationException("Account changed") }
    private fun credentials() = checkNotNull(token) { "Sign in to use your library." } to revision

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
            } catch (cancelled: CancellationException) { throw cancelled
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
        mutable.value = state.value.copy(searching = true, error = null, feedResults = emptyList(), searchResults = emptyList())
        try {
            val rows = if (feedId != null) api.episodes(current, feedId, query)
                else if (query.isBlank()) emptyList() else api.search(current, query)
            check(version)
            if (request != searchVersion) return
            val items = rows.map { row -> state.value.items.firstOrNull { it.episodeId == row.id && it.id in state.value.savedIds } ?: row.item(state.value) }
            mutable.value = state.value.copy(items = merge(state.value.items, items), searching = false,
                feedResults = if (feedId != null) items.map { it.id } else emptyList(),
                searchResults = if (feedId == null) items.map { it.id } else emptyList())
        } catch (cancelled: CancellationException) { throw cancelled
        } catch (failure: Exception) {
            check(version)
            if (request == searchVersion) mutable.value = state.value.copy(searching = false, error = message(failure))
        }
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
        val row = api.episode(current, episodeId)
        check(version)
        require(row.id == episodeId) { "The requested item could not be found." }
        return acceptVoiceEpisode(row, version)
    }

    /** Fresh read-only results without replacing the search currently displayed in the app. */
    suspend fun shortcutItems(feedId: String? = null): List<LibraryItem> {
        if (!state.value.live) return state.value.items.filter { feedId == null || it.sourceId == feedId }
        val (current, version) = credentials()
        if (feedId != null) require(state.value.feeds.any { it.id == feedId }) { "That show is no longer followed." }
        val rows = if (feedId == null) api.latest(current) else api.episodes(current, feedId, "")
        check(version)
        val items = rows.map { it.item(state.value) }
        mutable.value = state.value.copy(items = merge(state.value.items, items))
        return items.map { row -> state.value.items.first { it.id == row.id } }
    }

    suspend fun content(id: String): LibraryItem {
        val (current, version) = credentials()
        val item = state.value.items.first { it.id == id }
        if (item.kind == ContentKind.Podcast || item.textLoaded) return item
        val text = api.text(current, checkNotNull(item.episodeId), item.contentId)
        check(version)
        if (state.value.items.firstOrNull { it.id == id }?.contentId != item.contentId) throw CancellationException("Article changed")
        require(text.episodeId == item.episodeId && (item.contentId == null || text.contentId == item.contentId)) { "The article version changed. Refresh your library and try again." }
        require(text.text.isNotBlank()) { "The article has no readable text yet." }
        val loaded = item.copy(text = text.text, html = text.html, wordCount = text.wordCount,
            contentVersion = digest(text.text), textLoaded = true, contentId = text.contentId)
        mutable.value = state.value.copy(items = merge(state.value.items, listOf(loaded)))
        return loaded
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
        { mutable.value = state.value.copy(feeds = (state.value.feeds.filterNot { it.id == feed.id } + feed).sortedBy { it.title.lowercase() }) }
    }
    private suspend fun <T> discovery(work: suspend (DiscoveryApi, String) -> T): T {
        val (current, version) = credentials()
        val result = work(checkNotNull(api as? DiscoveryApi) { "Source discovery is unavailable." }, current)
        check(version)
        return result
    }
    private suspend fun acceptEpisodes(rows: List<RemoteEpisode>): List<String> {
        val (current, version) = credentials()
        val owner = state.value.owner ?: digest(server + ":" + api.userId(current))
        check(version)
        val next = state.value.copy(owner = owner)
        // Saved articles retain their selected immutable content version.
        val items = rows.map { row -> next.items.firstOrNull { it.episodeId == row.id && it.id in next.savedIds } ?: row.item(next) }
        mutable.value = next.copy(items = merge(next.items, items))
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
                latestIds = emptyList(), searching = false)
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
    private fun acceptSaved(row: RemoteEpisode): LibraryItem {
        // A search started before replacement must not restore the old selection.
        searchVersion++
        val added = row.item(state.value)
        val items = merge(state.value.items, listOf(added))
        val savedIds = if (added.id in state.value.savedIds) state.value.savedIds else listOf(added.id) + state.value.savedIds
        mutable.value = state.value.copy(items = items, savedIds = savedIds, searching = false)
        return items.first { it.id == added.id }
    }
    fun voiceOperation(request: com.henrydashwood.magpie.voice.VoiceRequest, sessionRevision: Int): com.henrydashwood.magpie.voice.VoiceOperation {
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
        check(sessionRevision)
        require(state.value.live && row.id > 0)
        val item = row.item(state.value)
        mutable.value = state.value.copy(items = merge(state.value.items, listOf(item)))
        state.value.items.first { it.id == item.id }
    }
    private fun requireItem(item: LibraryItem) { require(state.value.items.any { it.id == item.id }) { "This item belongs to a different library." } }
    private suspend fun mutate(work: suspend (String) -> (() -> Unit)) {
        val (current, version) = credentials()
        writes.withLock {
            check(version)
            val commit = work(current)
            check(version)
            commit()
        }
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
            completed = completed, dismissed = dismissed, captureError = captureError)
    }
    private fun merge(existing: List<LibraryItem>, rows: List<LibraryItem>): List<LibraryItem> {
        val items = existing.associateBy { it.id }.toMutableMap()
        for (row in rows) {
            val old = items[row.id]
            items[row.id] = if (old?.textLoaded == true && !row.textLoaded && old.contentId == row.contentId)
                row.copy(text = old.text, html = old.html, textLoaded = true, contentVersion = old.contentVersion, wordCount = row.wordCount ?: old.wordCount) else row
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
