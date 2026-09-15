package com.henrydashwood.magpie.data

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import java.time.Instant
import java.util.UUID

data class PendingArticle(val id: String = UUID.randomUUID().toString(), val url: String, val savedAt: String = Instant.now().toString())
interface ArticleInbox {
    suspend fun pending(owner: String): List<PendingArticle>
    suspend fun add(owner: String, article: PendingArticle)
    suspend fun remove(owner: String, id: String)
}
interface AccountIdentityStore {
    fun owner(sessionKey: String): String?
    suspend fun remember(sessionKey: String, owner: String)
}
interface SavedArticleApi {
    suspend fun capture(token: String, article: PendingArticle): RemoteEpisode
    suspend fun retrySaved(token: String, episodeId: Int): RemoteEpisode
    suspend fun replaceSaved(token: String, episodeId: Int): RemoteEpisode
}
interface SavedArticleRepository {
    suspend fun captureSaved(article: PendingArticle, revision: Int)
    suspend fun prepareSaved(item: LibraryItem, replace: Boolean, revision: Int): LibraryItem
}
data class SavedPreparationState(val owner: String? = null, val revision: Int = 0,
    val pending: List<PendingArticle> = emptyList(), val busy: Boolean = false,
    val itemId: String? = null, val error: String? = null, val replacement: LibraryItem? = null)

/** Foreground queue. Only confirmed saves leave disk; every reply belongs to its initiating account. */
class SavedPreparation(private val scope: CoroutineScope, private val repository: SavedArticleRepository,
    private val inbox: ArticleInbox, private val announce: (String) -> Unit = {},
    private val changed: (LibraryItem, LibraryItem) -> Unit = { _, _ -> }) {
    private val mutable = MutableStateFlow(SavedPreparationState())
    val state = mutable.asStateFlow()
    private var generation = 0
    private var job: Job? = null
    fun activate(owner: String?, revision: Int) {
        if (owner == state.value.owner && revision == state.value.revision) return
        generation++; job?.cancel()
        mutable.value = SavedPreparationState(owner, revision)
        sync()
    }
    suspend fun add(url: String, syncAfter: Boolean = true) {
        val before = state.value
        val owner = checkNotNull(before.owner) { "Connect to Magpie once to identify your account before saving links." }
        check(!before.busy) { "Please wait for the current article update to finish." }
        val version = generation
        inbox.add(owner, PendingArticle(url = validateLink(url)))
        if (version != generation) throw CancellationException("Account changed")
        val pending = inbox.pending(owner)
        if (version != generation) throw CancellationException("Account changed")
        mutable.value = state.value.copy(pending = pending)
        announce("Link saved on this device")
        if (syncAfter) sync()
    }
    fun sync() = run {
        reload()
        while (active()) {
            val article = state.value.pending.firstOrNull() ?: break
            repository.captureSaved(article, revision)
            if (!active()) return@run
            inbox.remove(owner, article.id)
            reload()
        }
    }
    fun remove(article: PendingArticle) = run {
        inbox.remove(owner, article.id); reload()
    }
    fun requestReplacement(item: LibraryItem) {
        if (!state.value.busy) mutable.value = state.value.copy(replacement = item, error = null)
    }
    fun cancelReplacement() { if (!state.value.busy) mutable.value = state.value.copy(replacement = null) }
    fun replace() { state.value.replacement?.let { prepare(it, true) } }
    fun retry(item: LibraryItem) = prepare(item, false)
    private fun prepare(item: LibraryItem, replace: Boolean) = run {
        update { it.copy(itemId = item.id, replacement = null) }
        val updated = repository.prepareSaved(item, replace, revision)
        if (active()) {
            changed(item, updated)
            if (updated.captureError != null) update { it.copy(error = updated.captureError) }
            else announce(if (replace) "Saved text replaced: ${updated.title}" else "Article prepared: ${updated.title}")
        }
    }
    private inner class Request(val version: Int, val owner: String, val revision: Int) {
        fun active() = version == generation
        fun update(change: (SavedPreparationState) -> SavedPreparationState) { if (active()) mutable.value = change(state.value) }
        suspend fun reload() { val rows = inbox.pending(owner); update { it.copy(pending = rows) } }
    }
    private fun run(work: suspend Request.() -> Unit) {
        val owner = state.value.owner ?: return
        if (state.value.busy) return
        val request = Request(generation, owner, state.value.revision)
        mutable.value = state.value.copy(busy = true, error = null)
        job = scope.launch {
            try { request.work() }
            catch (cancelled: CancellationException) { throw cancelled }
            catch (failure: Exception) { request.update { it.copy(error = AccountLibrary.message(failure)) } }
            finally { request.update { it.copy(busy = false, itemId = null) } }
        }
    }
}
