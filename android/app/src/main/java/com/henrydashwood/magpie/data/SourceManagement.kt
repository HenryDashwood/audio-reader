package com.henrydashwood.magpie.data

import java.net.URI
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

data class FeedSource(val id: String, val title: String, val url: String, val type: String,
    val primary: Boolean = false, val failing: Boolean = false) {
    // Private feed URLs may contain subscription tokens. Only display the host.
    val location: String get() = if (type == "email") "Email newsletter" else runCatching { URI(url).host }.getOrNull() ?: "Feed"
}
data class SourceGroup(val sources: List<FeedSource>, val available: List<LibraryFeed>)
enum class SourceChange { Combine, Separate, Unsubscribe }
interface SourceManagementApi {
    suspend fun feedSources(token: String, feedId: String): List<FeedSource>
    suspend fun changeSources(token: String, feedId: String, sourceId: String?, change: SourceChange)
}
interface SourceManagementRepository {
    suspend fun sourceGroup(feedId: String, sessionRevision: Int): SourceGroup
    suspend fun changeSourceGroup(feedId: String, sourceId: String?, change: SourceChange, sessionRevision: Int)
}
data class ManagementState(val feed: LibraryFeed? = null, val sessionRevision: Int = 0, val showing: Boolean = false,
    val busy: Boolean = false, val loaded: Boolean = false, val sources: List<FeedSource> = emptyList(),
    val available: List<LibraryFeed> = emptyList(), val error: String? = null, val notice: String? = null)

class SourceManager(private val scope: CoroutineScope, private val repository: SourceManagementRepository,
    private val announce: (String) -> Unit = {}) {
    private val mutable = MutableStateFlow(ManagementState())
    val state = mutable.asStateFlow()
    private var generation = 0
    private var job: Job? = null
    fun reset() { generation++; job?.cancel(); mutable.value = ManagementState() }
    fun close() { if (!state.value.busy) reset() }
    fun open(feed: LibraryFeed, sessionRevision: Int) {
        if (state.value.busy) return
        reset(); mutable.value = ManagementState(feed, sessionRevision, showing = true)
        reload()
    }
    fun reload() = run {
        val feed = state.value.feed ?: return@run
        val group = repository.sourceGroup(feed.id, state.value.sessionRevision)
        update { it.copy(sources = group.sources, available = group.available, loaded = true) }
    }
    fun combine(other: LibraryFeed) {
        if (state.value.available.none { it.id == other.id }) return
        change(other.id, SourceChange.Combine)
    }
    fun separate(source: FeedSource) {
        if (source.primary || state.value.sources.none { it.id == source.id && !it.primary }) return
        change(source.id, SourceChange.Separate)
    }
    fun unsubscribe(feed: LibraryFeed, sessionRevision: Int) {
        if (state.value.busy) return
        reset(); mutable.value = ManagementState(feed, sessionRevision, showing = true)
        change(null, SourceChange.Unsubscribe)
    }
    private fun change(sourceId: String?, change: SourceChange) = run {
        val feed = state.value.feed ?: return@run
        val revision = state.value.sessionRevision
        repository.changeSourceGroup(feed.id, sourceId, change, revision)
        if (!active()) return@run
        val message = when (change) {
            SourceChange.Combine -> "Sources combined"
            SourceChange.Separate -> "Source separated"
            SourceChange.Unsubscribe -> if (feed.forwarded) "Unsubscribed from ${feed.title}. To stop forwarded emails, remove the forwarding rule in your email account." else "Unsubscribed from ${feed.title}"
        }
        // The open dialog announces its notice; unsubscribe closes it and uses the app notice.
        if (change == SourceChange.Unsubscribe) announce(message)
        update { it.copy(notice = message, sources = emptyList(), available = emptyList(), loaded = false,
            showing = change != SourceChange.Unsubscribe) }
        if (change != SourceChange.Unsubscribe) {
            val group = repository.sourceGroup(feed.id, revision)
            update { it.copy(sources = group.sources, available = group.available, loaded = true) }
        }
    }
    private inner class Request(val version: Int) {
        fun active() = version == generation
        fun update(transform: (ManagementState) -> ManagementState) { if (active()) mutable.value = transform(state.value) }
    }
    private fun run(work: suspend Request.() -> Unit) {
        if (state.value.busy) return
        val request = Request(++generation)
        mutable.value = state.value.copy(busy = true, error = null)
        job = scope.launch {
            try { request.work() }
            catch (cancelled: CancellationException) { throw cancelled }
            catch (failure: Exception) { request.update { it.copy(error = AccountLibrary.message(failure)) } }
            finally { request.update { it.copy(busy = false) } }
        }
    }
}
