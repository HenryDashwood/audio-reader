package com.henrydashwood.magpie.data

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import java.net.URI
import java.text.Normalizer

data class DiscoveryState(val showing: Boolean = false, val query: String = "", val searched: Boolean = false,
    val loading: Boolean = false, val following: Boolean = false, val error: String? = null,
    val sources: List<SourceResult> = emptyList(), val itemIds: List<String> = emptyList(),
    val candidates: List<SourceResult>? = null, val selected: SourceResult? = null,
    val preview: SourcePreview? = null, val web: SourceResult? = null, val webMessage: String? = null,
    val askingConsent: Boolean = false, val signup: NewsletterSignup? = null)

/** What typed search lists from the directories, once what she follows or another source listed is gone. */
data class DirectoryResults(val publications: List<SourceResult> = emptyList(), val podcasts: List<SourceResult> = emptyList(),
    val web: SourceResult? = null, val publicationsFirst: Boolean = false, val offersWebSearch: Boolean = true) {
    val isEmpty get() = publications.isEmpty() && podcasts.isEmpty() && web == null
}

/** UI requests and replies belong to both a query generation and the repository session. */
class SourceDiscovery(private val scope: CoroutineScope, private val repository: SourceRepository) {
    private val mutable = MutableStateFlow(DiscoveryState())
    val state = mutable.asStateFlow()
    private var job: Job? = null
    private var generation = 0
    fun reset() { generation++; job?.cancel(); mutable.value = DiscoveryState() }
    fun open() { reset(); mutable.value = DiscoveryState(showing = true) }
    fun close() { if (!state.value.following) reset() }
    fun edit(query: String) {
        if (state.value.following) return
        generation++; job?.cancel()
        mutable.value = DiscoveryState(showing = true, query = query.take(8192))
        if (query.trim().length >= 2 && !isAddress(query)) search(350)
    }
    fun submit() { if (isAddress(state.value.query)) findFeeds() else search(0) }
    private fun search(debounce: Long) {
        val query = state.value.query.trim().take(200)
        if (query.length < 2) return
        request {
            mutable.value = state.value.copy(loading = true, error = null)
            delay(debounce)
            val result = repository.findSources(query)
            update { it.copy(sources = result.sources, itemIds = result.itemIds, searched = true, error = result.error) }
        }
    }
    private fun findFeeds() = request {
        mutable.value = state.value.copy(loading = true, error = null, candidates = null, signup = null)
        val results = repository.discoverSources(address(state.value.query))
        update { it.copy(candidates = results, searched = true,
            error = if (results.isEmpty()) "Magpie reached that site, but it did not advertise a readable feed." else null) }
        if (results.size == 1 && active()) loadPreview(results.single())
    }
    fun select(source: SourceResult) = request { loadPreview(source) }
    private suspend fun Request.loadPreview(source: SourceResult) {
        update { it.copy(selected = source, preview = null, loading = true, error = null) }
        val preview = repository.previewSource(source.url)
        update { it.copy(preview = preview) }
    }
    fun back() {
        if (state.value.following) return
        generation++; job?.cancel()
        mutable.value = state.value.copy(selected = null, preview = null, candidates = if (state.value.selected == null) null else state.value.candidates,
            loading = false, error = null, askingConsent = false)
    }
    fun retry() {
        val selected = state.value.selected
        if (selected != null) select(selected) else submit()
    }
    fun signUpByEmail() {
        if (state.value.following || state.value.loading || !isAddress(state.value.query)) return
        val newsletters = repository as? NewsletterRepository ?: return
        val url = runCatching { address(state.value.query) }.getOrNull() ?: return
        request {
            update { it.copy(following = true, error = null, signup = null) }
            val result = newsletters.signUpForNewsletter(url)
            update { it.copy(signup = result, candidates = null, selected = null, preview = null) }
        }
    }
    fun follow() {
        val preview = state.value.preview ?: return
        if (preview.subscribed || state.value.following) return
        request {
            update { it.copy(following = true, error = null) }
            val subscribed = repository.followSource(preview)
            update { it.copy(preview = subscribed) }
        }
    }
    fun unfollow() {
        val preview = state.value.preview ?: return
        if (!preview.subscribed || state.value.following) return
        request {
            update { it.copy(following = true, error = null) }
            val updated = repository.unfollowSource(preview)
            update { it.copy(preview = updated) }
        }
    }
    fun searchWeb() = request {
        update { it.copy(loading = true, webMessage = null, error = null) }
        if (!repository.aiConsent()) update { it.copy(askingConsent = true) }
        else lookupWeb()
    }
    fun allowAI() = request {
        update { it.copy(loading = true, error = null) }
        check(repository.setAIConsent(true)) { "Your choice could not be saved. Please try again." }
        update { it.copy(askingConsent = false) }
        lookupWeb()
    }
    fun declineAI() { generation++; job?.cancel(); mutable.value = state.value.copy(askingConsent = false, loading = false, error = null) }
    private suspend fun Request.lookupWeb() {
        if (!active()) return
        val result = repository.findPublication(state.value.query.trim().take(200))
        update { it.copy(web = result, webMessage = if (result == null) "No matching publication was found on the web." else null) }
    }
    private inner class Request(val version: Int) {
        fun active() = version == generation
        fun update(transform: (DiscoveryState) -> DiscoveryState) { if (active()) mutable.value = transform(state.value) }
    }
    private fun request(work: suspend Request.() -> Unit) {
        generation++; job?.cancel()
        val request = Request(generation)
        job = scope.launch {
            try { request.work() }
            catch (cancelled: CancellationException) { throw cancelled }
            catch (failure: Exception) { request.update { it.copy(error = AccountLibrary.message(failure)) } }
            finally { request.update { it.copy(loading = false, following = false) } }
        }
    }
    companion object {
        fun isAddress(query: String): Boolean {
            val text = query.trim()
            return text.contains("://") || (text.contains('.') && text.none(Char::isWhitespace))
        }
        fun address(query: String) = validateLink(query.trim().let { if (it.contains("://")) it else "https://$it" })

        /** As on iOS: one row per feed, and the web search offered unless something listed is plausibly what she typed. */
        fun directoryResults(query: String, local: List<LibraryFeed>, sources: List<SourceResult>, web: SourceResult?): DirectoryResults {
            val listed = mutableSetOf<String>()
            val fresh = sources.filter { source ->
                local.none { it.url == source.url || it.title.equals(source.title, ignoreCase = true) } && listed.add(feedIdentity(source.url))
            }
            // A web find that is already listed is the row she can already see.
            val found = web?.takeUnless { result -> feedIdentity(result.url) in listed || local.any { it.title.equals(result.title, ignoreCase = true) } }
            val named = local.map { it.title } + fresh.map { it.title } + listOfNotNull(found?.title)
            return DirectoryResults(fresh.filter { it.publication }, fresh.filterNot { it.publication }, found,
                fresh.firstOrNull()?.publication == true, named.none { titleNames(it, query) })
        }

        /** Does the title contain every word she typed, allowing for a typo? */
        fun titleNames(title: String, query: String): Boolean {
            val terms = words(query)
            val titleWords = words(title)
            return terms.isNotEmpty() && terms.all { term -> titleWords.any { it.startsWith(term) || withinOneEdit(term, it) } }
        }

        private fun words(value: String) = Normalizer.normalize(value.lowercase(), Normalizer.Form.NFD)
            .replace(Regex("\\p{M}+"), "").split(Regex("[^\\p{L}\\p{N}]+")).filter { it.isNotEmpty() }

        private fun withinOneEdit(left: String, right: String): Boolean {
            if (left == right) return true
            if (minOf(left.length, right.length) < 4 || kotlin.math.abs(left.length - right.length) > 1) return false
            if (left.length == right.length) {
                val differences = left.indices.filter { left[it] != right[it] }
                return differences.size == 1 || (differences.size == 2 && differences[1] == differences[0] + 1 &&
                    left[differences[0]] == right[differences[1]] && left[differences[1]] == right[differences[0]])
            }
            val (shorter, longer) = if (left.length < right.length) left to right else right to left
            val index = shorter.indices.firstOrNull { shorter[it] != longer[it] } ?: shorter.length
            return shorter.substring(index) == longer.substring(index + 1)
        }

        /** HTTP and HTTPS spellings of a feed are the same feed. */
        private fun feedIdentity(url: String) = runCatching {
            val uri = URI(url)
            URI("https", uri.rawAuthority?.lowercase(), uri.rawPath, uri.rawQuery, null).toString()
        }.getOrDefault(url)
    }
}
