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

data class LibraryState(val live: Boolean = false, val revision: Int = 0, val owner: String? = null,
    val items: List<LibraryItem> = emptyList(), val feeds: List<LibraryFeed> = emptyList(),
    val latestIds: List<String> = emptyList(), val savedIds: List<String> = emptyList(),
    val feedResults: List<String> = emptyList(), val searchResults: List<String> = emptyList(),
    val loading: Boolean = false, val searching: Boolean = false, val error: String? = null)

/** Main-dispatcher state. Every result is bound to the initiating session revision.
 * Account data is kept in memory; a failed load never falls back to sample data. */
class AccountLibrary(private val api: LibraryApi, private val server: String, initiallySignedIn: Boolean = false) {
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
        mutable.value = if (value == null) preview() else LibraryState(live = true, revision = revision, loading = true)
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
        mutable.value = state.value.copy(searching = true, error = null, feedResults = emptyList(), searchResults = emptyList())
        try {
            val rows = if (feedId != null) api.episodes(current, feedId, query)
                else if (query.isBlank()) emptyList() else api.search(current, query)
            check(version)
            if (request != searchVersion) return
            val items = rows.map { it.item(state.value) }
            mutable.value = state.value.copy(items = merge(state.value.items, items), searching = false,
                feedResults = if (feedId != null) items.map { it.id } else emptyList(),
                searchResults = if (feedId == null) items.map { it.id } else emptyList())
        } catch (cancelled: CancellationException) { throw cancelled
        } catch (failure: Exception) {
            check(version)
            if (request == searchVersion) mutable.value = state.value.copy(searching = false, error = message(failure))
        }
    }

    suspend fun content(id: String): LibraryItem {
        val (current, version) = credentials()
        val item = state.value.items.first { it.id == id }
        if (item.kind == ContentKind.Podcast || item.textLoaded) return item
        val text = api.text(current, checkNotNull(item.episodeId), item.contentId)
        check(version)
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
            episodeId = id, contentId = contentId, sourceId = state.feeds.firstOrNull { it.url == feedUrl }?.id ?: feedUrl ?: source,
            audioUrl = audioUrl, wordCount = wordCount, textLoaded = podcast,
            remotePositionMs = if (completed) 0 else (positionSeconds * 1000).toLong().coerceAtLeast(0),
            completed = completed, dismissed = dismissed, captureError = captureError)
    }
    private fun merge(existing: List<LibraryItem>, rows: List<LibraryItem>): List<LibraryItem> {
        val items = existing.associateBy { it.id }.toMutableMap()
        for (row in rows) {
            val old = items[row.id]
            items[row.id] = if (old?.textLoaded == true && !row.textLoaded && old.contentId == row.contentId)
                row.copy(text = old.text, html = old.html, textLoaded = true, contentVersion = old.contentVersion) else row
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
