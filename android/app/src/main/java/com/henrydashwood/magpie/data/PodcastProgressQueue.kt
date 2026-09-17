package com.henrydashwood.magpie.data

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

data class ProgressSample(val seconds: Double, val completed: Boolean = false) {
    init { require(seconds.isFinite() && seconds >= 0) }
}
data class QueuedPodcastProgress(val episodeId: Int, val playbackId: String, val baselineRevision: String,
    val latest: ProgressSample, val pending: PodcastProgressReport? = null, val pendingPlaybackId: String? = null,
    val sampled: Boolean = false, val blocked: Boolean = false, val dismissed: Boolean = false,
    val guards: Set<String> = emptySet()) {
    init {
        require(episodeId > 0 && playbackId.isNotBlank())
        require(baselineRevision.matches(Regex("[a-f0-9]{64}")))
        require((pending == null) == (pendingPlaybackId == null))
    }
}
interface PodcastProgressStore {
    suspend fun read(owner: String): List<QueuedPodcastProgress>
    suspend fun write(owner: String, entries: List<QueuedPodcastProgress>)
}
class ProgressConflict(val episode: RemoteEpisode) : Exception()

/** Main-dispatcher coordinator. Disk changes never wait for the network lock. */
class PodcastProgressQueue(private val store: PodcastProgressStore) {
    private val records = Mutex()
    private val network = Mutex()

    suspend fun start(owner: String, episodeId: Int, playbackId: String, revision: String,
        sample: ProgressSample, dismissed: Boolean, valid: () -> Boolean = { true }) = records.withLock {
        ensure(valid)
        val entries = store.read(owner); ensure(valid)
        val old = entries.find { it.episodeId == episodeId }
        val next = QueuedPodcastProgress(episodeId, playbackId, revision, sample,
            old?.pending, old?.pendingPlaybackId, dismissed = dismissed, guards = old?.guards.orEmpty())
        store.write(owner, entries.filterNot { it.episodeId == episodeId } + next)
        ensure(valid)
    }

    suspend fun record(owner: String, episodeId: Int, playbackId: String, sample: ProgressSample,
        valid: () -> Boolean = { true }): Boolean = records.withLock {
        ensure(valid)
        val entries = store.read(owner); ensure(valid)
        val old = entries.find { it.episodeId == episodeId && it.playbackId == playbackId && !it.blocked && it.guards.isEmpty() }
            ?: return@withLock false
        // After natural completion, late pause callbacks from the same playback
        // session cannot turn the final report back into an unfinished clock.
        if (old.sampled && old.latest.completed && !sample.completed) return@withLock false
        val report = old.pending ?: PodcastProgressReport(old.baselineRevision, sample.seconds, sample.completed)
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

    suspend fun entries(owner: String): List<QueuedPodcastProgress> = records.withLock { store.read(owner) }
    suspend fun clear(owner: String) = records.withLock { store.write(owner, emptyList()) }
    suspend fun awaitNetwork() = network.withLock { }

    /** One pass: a continuously advancing clock cannot starve a filing/drain request. */
    suspend fun flush(owner: String, valid: () -> Boolean, send: suspend (Int, PodcastProgressReport) -> PodcastProgressReceipt,
        applied: suspend (RemoteEpisode, Boolean) -> Unit) = network.withLock {
        ensure(valid)
        val pending = entries(owner).filter { it.pending != null && !it.blocked && it.guards.isEmpty() }
        for (entry in pending) {
            ensure(valid)
            val request = checkNotNull(entry.pending)
            if (entries(owner).none { it.episodeId == entry.episodeId && it.pending?.requestId == request.requestId && !it.blocked && it.guards.isEmpty() }) continue
            val receipt = try { send(entry.episodeId, request) }
                catch (conflict: ProgressConflict) { PodcastProgressReceipt(conflict.episode, "") }
            ensure(valid)
            val current = receipt.episode
            require(current.id == entry.episodeId && current.progressRevision?.matches(Regex("[a-f0-9]{64}")) == true)
            val changed = receipt.changedSinceAcceptance
            val accepted = records.withLock record@ {
                ensure(valid)
                val values = store.read(owner); ensure(valid)
                val old = values.find { it.episodeId == entry.episodeId && it.pending?.requestId == request.requestId && !it.blocked }
                    ?: return@record false
                val freshIntent = old.playbackId != old.pendingPlaybackId && old.baselineRevision == current.progressRevision
                val next = if (changed && !freshIntent) old.copy(blocked = true, pending = null, pendingPlaybackId = null)
                else {
                    val revision = if (old.playbackId == old.pendingPlaybackId || old.baselineRevision == request.expectedRevision)
                        checkNotNull(current.progressRevision) else old.baselineRevision
                    val newer = old.sampled && (old.playbackId != old.pendingPlaybackId ||
                        old.latest != ProgressSample(request.seconds, request.completed))
                    old.copy(baselineRevision = revision, dismissed = if (revision == current.progressRevision) current.dismissed else old.dismissed,
                        pending = if (newer) PodcastProgressReport(revision, old.latest.seconds, old.latest.completed) else null,
                        pendingPlaybackId = if (newer) old.playbackId else null)
                }
                store.write(owner, values.map { if (it.episodeId == entry.episodeId) next else it })
                ensure(valid)
                true
            }
            if (accepted) applied(current, changed)
        }
    }
    private fun ensure(valid: () -> Boolean) { if (!valid()) throw CancellationException("Account changed") }
}
