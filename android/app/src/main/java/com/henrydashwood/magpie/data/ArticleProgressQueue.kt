package com.henrydashwood.magpie.data

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

data class ArticleProgressSample(val textVersion: String, val contentId: Int?, val offsetUtf16: Int, val completed: Boolean = false) {
    init {
        require(textVersion.matches(Regex("[a-f0-9]{64}")) && offsetUtf16 >= 0)
        require(contentId == null || contentId > 0)
    }
    fun report(revision: String) = ArticleProgressReport(revision, textVersion, contentId, offsetUtf16, completed)
}
data class QueuedArticleProgress(val episodeId: Int, val playbackId: String, val baselineRevision: String,
    val latest: ArticleProgressSample, val pending: ArticleProgressReport? = null, val pendingPlaybackId: String? = null,
    val sampled: Boolean = false, val blocked: Boolean = false, val dismissed: Boolean = false,
    val guards: Set<String> = emptySet()) {
    init {
        require(episodeId > 0 && playbackId.isNotBlank())
        require(baselineRevision.matches(Regex("[a-f0-9]{64}")))
        require((pending == null) == (pendingPlaybackId == null))
    }
}
interface ArticleProgressStore {
    suspend fun read(owner: String): List<QueuedArticleProgress>
    suspend fun write(owner: String, entries: List<QueuedArticleProgress>)
}
class ArticleProgressConflict(val episode: RemoteEpisode, val progress: ArticleProgressState) : Exception()

/** Main-dispatcher coordinator. Disk changes never wait for the network lock. */
class ArticleProgressQueue(private val store: ArticleProgressStore) {
    private val records = Mutex()
    private val network = Mutex()

    suspend fun start(owner: String, episodeId: Int, playbackId: String, revision: String,
        sample: ArticleProgressSample, dismissed: Boolean, valid: () -> Boolean = { true }) = records.withLock {
        ensure(valid)
        val entries = store.read(owner); ensure(valid)
        val old = entries.find { it.episodeId == episodeId }
        val next = QueuedArticleProgress(episodeId, playbackId, revision, sample,
            old?.pending, old?.pendingPlaybackId, dismissed = dismissed, guards = old?.guards.orEmpty())
        store.write(owner, entries.filterNot { it.episodeId == episodeId } + next)
        ensure(valid)
    }

    suspend fun record(owner: String, episodeId: Int, playbackId: String, sample: ArticleProgressSample,
        valid: () -> Boolean = { true }): Boolean = records.withLock {
        ensure(valid)
        val entries = store.read(owner); ensure(valid)
        val old = entries.find { it.episodeId == episodeId && it.playbackId == playbackId && !it.blocked && it.guards.isEmpty() }
            ?: return@withLock false
        if (sample.textVersion != old.latest.textVersion || sample.contentId != old.latest.contentId) return@withLock false
        // After natural completion, late pause callbacks from the same playback
        // session cannot turn the final report back into an unfinished clock.
        if (old.sampled && old.latest.completed && !sample.completed) return@withLock false
        val report = old.pending ?: sample.report(old.baselineRevision)
        val next = old.copy(latest = sample, sampled = true, pending = report,
            pendingPlaybackId = old.pendingPlaybackId ?: playbackId)
        store.write(owner, entries.map { if (it.episodeId == episodeId) next else it })
        ensure(valid)
        true
    }

    /** Persist this before sending a filing action whose reply might be lost. */
    suspend fun block(owner: String, episodeIds: Set<Int>, valid: () -> Boolean = { true }) = records.withLock {
        ensure(valid)
        val entries = store.read(owner); ensure(valid)
        store.write(owner, entries.map { if (it.episodeId in episodeIds) it.copy(blocked = true, pending = null,
            pendingPlaybackId = null) else it })
        ensure(valid)
    }

    suspend fun hold(owner: String, episodeIds: Set<Int>, requestId: String, valid: () -> Boolean = { true }) = records.withLock {
        ensure(valid)
        val entries = store.read(owner); ensure(valid)
        store.write(owner, entries.map { if (it.episodeId in episodeIds) it.copy(guards = it.guards + requestId) else it })
        ensure(valid)
    }
    suspend fun confirm(owner: String, requestId: String, valid: () -> Boolean = { true }) = records.withLock {
        ensure(valid)
        val entries = store.read(owner); ensure(valid)
        store.write(owner, entries.map { it.copy(guards = it.guards - requestId) })
        ensure(valid)
    }

    suspend fun entries(owner: String): List<QueuedArticleProgress> = records.withLock { store.read(owner) }
    suspend fun clear(owner: String) = records.withLock { store.write(owner, emptyList()) }
    suspend fun awaitNetwork() = network.withLock { }

    /** One pass: a continuously advancing clock cannot starve a filing/drain request. */
    suspend fun flush(owner: String, valid: () -> Boolean, send: suspend (Int, ArticleProgressReport) -> ArticleProgressReceipt,
        applied: suspend (RemoteEpisode, ArticleProgressState, Boolean) -> Unit) = network.withLock {
        ensure(valid)
        val pending = entries(owner).filter { it.pending != null && !it.blocked && it.guards.isEmpty() }
        for (entry in pending) {
            ensure(valid)
            val request = checkNotNull(entry.pending)
            if (entries(owner).none { it.episodeId == entry.episodeId && it.pending?.requestId == request.requestId && !it.blocked && it.guards.isEmpty() }) continue
            val receipt = try { send(entry.episodeId, request) }
                catch (conflict: ArticleProgressConflict) { ArticleProgressReceipt(conflict.episode, conflict.progress, "") }
            ensure(valid)
            val current = receipt.episode
            require(current.id == entry.episodeId && receipt.progress.revision.matches(Regex("[a-f0-9]{64}")))
            val changed = receipt.changedSinceAcceptance
            val accepted = records.withLock record@ {
                ensure(valid)
                val values = store.read(owner); ensure(valid)
                val old = values.find { it.episodeId == entry.episodeId && it.pending?.requestId == request.requestId && !it.blocked }
                    ?: return@record false
                val freshIntent = old.playbackId != old.pendingPlaybackId && old.baselineRevision == receipt.progress.revision &&
                    old.latest.textVersion == receipt.progress.textVersion && old.latest.contentId == receipt.progress.contentId
                val next = if (changed && !freshIntent) old.copy(blocked = true, pending = null, pendingPlaybackId = null)
                else {
                    val revision = if (old.playbackId == old.pendingPlaybackId || old.baselineRevision == request.expectedRevision)
                        receipt.progress.revision else old.baselineRevision
                    val newer = old.sampled && (old.playbackId != old.pendingPlaybackId ||
                        old.latest != ArticleProgressSample(request.textVersion, request.contentId, request.offsetUtf16, request.completed))
                    old.copy(baselineRevision = revision, dismissed = if (revision == receipt.progress.revision) current.dismissed else old.dismissed,
                        pending = if (newer) old.latest.report(revision) else null,
                        pendingPlaybackId = if (newer) old.playbackId else null)
                }
                store.write(owner, values.map { if (it.episodeId == entry.episodeId) next else it })
                ensure(valid)
                true
            }
            if (accepted) applied(current, receipt.progress, changed)
        }
    }
    private fun ensure(valid: () -> Boolean) { if (!valid()) throw CancellationException("Account changed") }
}
