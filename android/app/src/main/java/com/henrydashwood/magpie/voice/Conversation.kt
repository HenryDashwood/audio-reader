package com.henrydashwood.magpie.voice

import java.util.UUID
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.withContext
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/** Account/server-scoped text context. Never stores microphone recordings. */
data class ConversationTurn(val speaker: String, val text: String) {
    init { require(speaker in setOf("her", "app")) }
}
data class VoiceRequest(val transcript: String, val requestId: String = UUID.randomUUID().toString(),
    val viewedEpisodeId: Int? = null, val nowPlayingEpisodeId: Int? = null,
    val turns: List<ConversationTurn> = emptyList(), val recentActions: List<String> = emptyList(),
    val country: String? = null, val clarificationId: String? = null, val selectedOptionId: String? = null,
    val timezone: String = java.util.TimeZone.getDefault().id) {
    init {
        require(transcript.isNotBlank() && transcript.length <= 2_000)
        require(requestId.matches(Regex("[a-zA-Z0-9-]{1,64}")))
        require(turns.size <= 8 && recentActions.size <= 8)
        require(country == null || country.matches(Regex("[A-Za-z]{2}")))
    }
}

data class ConversationPreferences(val keepListening: Boolean = true, val followUpSeconds: Int = 15) {
    init { require(followUpSeconds in waitOptions) }
    companion object { val waitOptions = listOf(10, 15, 20, 30) }
}

/** A typed route must retain its original target and must never become an AI command. */
data class StructuredLibraryRequest(val action: String, val episodeId: Int?, val useCurrent: Boolean = false) {
    init {
        require(action in setOf("mark_played", "dismiss", "restore", "undo"))
        require(if (action == "undo") episodeId == null && !useCurrent else episodeId != null && episodeId > 0)
    }
    fun validate(response: VoiceResponse) {
        require(response.actions.isEmpty() && response.action in setOf(VoiceAction.Played, VoiceAction.Dismiss,
            VoiceAction.Restore, VoiceAction.Subscribed, VoiceAction.Unsubscribed, VoiceAction.Unknown)) {
            "The library response could not be confirmed."
        }
        if (action != "undo") require(response.action.wire == action && response.episode?.id == episodeId) {
            "The library response did not match the requested item."
        }
    }
}
data class RecoverableVoiceRequest(val request: VoiceRequest, val receipt: VoiceResponse? = null,
    val structured: StructuredLibraryRequest? = null)
interface ConversationStore {
    suspend fun read(owner: String): List<RecoverableVoiceRequest>
    suspend fun write(owner: String, requests: List<RecoverableVoiceRequest>)
}

class Conversation(private val store: ConversationStore? = null,
    private val nowMillis: () -> Long = { System.nanoTime() / 1_000_000 }) {
    private val storage = Mutex()
    private var activation = 0
    private var restoredOwner: String? = null
    private var recoveries: List<RecoverableVoiceRequest> = emptyList()
    private var restoredRequests: Set<String> = emptySet()
    fun wasRestored(id: String) = id in restoredRequests
    val recoveryRequests: List<VoiceRequest> get() = recoveries.asReversed().map { it.request }
    val durable: Boolean get() = store != null
    fun structured(id: String) = recoveries.firstOrNull { it.request.requestId == id }?.structured
    fun unfinished(action: String, episodeId: Int? = null, useCurrent: Boolean = false, anyCurrent: Boolean = false): VoiceRequest? =
        recoveries.lastOrNull { row -> row.structured?.let {
            it.action == action && it.useCurrent == useCurrent && (anyCurrent || it.episodeId == episodeId)
        } == true }?.request
    fun structuredRequest(action: StructuredLibraryRequest, label: String): VoiceRequest {
        val request = request(label.take(2_000))
        recoveries = recoveries.map { if (it.request == request) it.copy(structured = action) else it }
        return request
    }

    suspend fun restore(account: String) = storage.withLock {
        if (store == null || restoredOwner == account) return@withLock
        val version = activation
        val saved = store.read(account)
        checkActivation(version)
        require(saved.map { it.request.requestId }.distinct().size == saved.size)
        // Callers restore before creating a request and share the execution lease.
        recoveries = saved
        restoredRequests = saved.map { it.request.requestId }.toSet()
        pending = saved.lastOrNull()?.request; receipt = saved.lastOrNull()?.receipt
        restoredOwner = account
    }
    suspend fun persist(account: String) {
        val version = activation
        storage.withLock {
            checkActivation(version)
            if (store != null) {
                check(restoredOwner == account) { "Open your unfinished requests before continuing." }
                store.write(account, recoveries)
                checkActivation(version)
            }
        }
    }
    suspend fun complete(request: VoiceRequest, account: String?, actions: List<String>, storageOwner: String) {
        val version = activation
        withContext(NonCancellable) {
            storage.withLock {
                checkActivation(version)
                if (owner != account || pending?.requestId != request.requestId) return@withLock
                if (store != null) {
                    check(restoredOwner == storageOwner)
                    store.write(storageOwner, recoveries.filterNot { it.request.requestId == request.requestId })
                    checkActivation(version)
                }
                applied(request, account, actions)
            }
        }
    }
    suspend fun clearStored(account: String) = storage.withLock { store?.write(account, emptyList()) }
    private fun checkActivation(version: Int) {
        if (version != activation) throw CancellationException("Account changed")
    }
    fun selectRecovery(id: String) {
        val saved = recoveries.firstOrNull { it.request.requestId == id }
            ?: throw VoiceFailure("That request is no longer waiting to be checked.")
        pending = saved.request; receipt = saved.receipt; revision++
        turns = saved.request.turns + ConversationTurn("her", saved.request.transcript)
        lastSpoke = nowMillis()
    }

    var owner: String? = null
        private set
    var turns: List<ConversationTurn> = emptyList()
        private set
    var pending: VoiceRequest? = null
        private set
    var clarification: VoiceClarification? = null
        private set
    var receipt: VoiceResponse? = null
        private set
    private var execution: String? = null
    val executing: Boolean get() = execution != null
    fun acquire(id: String): Boolean {
        if (execution != null) return false
        execution = id
        return true
    }
    fun release(id: String) { if (execution == id) execution = null }
    var recentActions: List<String> = emptyList()
        private set
    private var lastSpoke: Long? = null
    private var revision = 0
    fun activate(owner: String?) {
        if (this.owner == owner) return
        this.owner = owner; revision++; activation++; restoredOwner = null; recoveries = emptyList(); restoredRequests = emptySet()
        clear(); pending = null; receipt = null; execution = null; recentActions = emptyList()
    }
    fun abandonClarification() { clarification = null }
    fun clear() { turns = emptyList(); lastSpoke = null; clarification = null }
    fun forgetIfStale() {
        if (lastSpoke?.let { nowMillis() - it > 120_000 } == true) clear()
    }
    fun userSaid(text: String) { forgetIfStale(); add("her", text) }
    fun appSaid(text: String) { add("app", text) }
    private fun add(speaker: String, text: String) {
        if (text.isBlank()) return
        turns = turns + ConversationTurn(speaker, text)
        lastSpoke = nowMillis()
    }
    /** Capture history before appending the current transcript, as required by /command. */
    fun request(transcript: String, viewedEpisodeId: Int? = null, playingEpisodeId: Int? = null,
        country: String? = null, recover: Boolean = false, selectedOptionId: String? = null): VoiceRequest {
        forgetIfStale()
        require(transcript.isNotBlank() && transcript.length <= 2_000)
        if (recover && pending != null) {
            if (wasRestored(pending!!.requestId)) selectRecovery(pending!!.requestId)
            userSaid(transcript.trim()); return pending!!
        }
        check(recoveries.size < 100) { "Check your unfinished requests before starting another library request." }
        val request = VoiceRequest(transcript.trim(), viewedEpisodeId = viewedEpisodeId,
            nowPlayingEpisodeId = playingEpisodeId, country = country,
            clarificationId = clarification?.id, selectedOptionId = selectedOptionId,
            turns = turns.takeLast(8), recentActions = recentActions)
        userSaid(request.transcript)
        revision++; pending = request; receipt = null
        recoveries = recoveries + RecoverableVoiceRequest(request)
        return request
    }
    fun confirmed(request: VoiceRequest, account: String?, response: VoiceResponse) {
        if (owner == account && pending?.requestId == request.requestId) {
            structured(request.requestId)?.validate(response)
            clarification = response.clarification
            receipt = response
            recoveries = recoveries.map { if (it.request.requestId == request.requestId) it.copy(receipt = response) else it }
        }
    }
    /** Keep a receipt until its client-side effects have succeeded, including after cancellation. */
    fun applied(request: VoiceRequest, account: String?, actions: List<String>) {
        if (owner != account || pending?.requestId != request.requestId) return
        clarification = receipt?.clarification
        recoveries = recoveries.filterNot { it.request.requestId == request.requestId }
        restoredRequests = restoredRequests - request.requestId
        pending = recoveries.lastOrNull()?.request; receipt = recoveries.lastOrNull()?.receipt
        recentActions = (recentActions + actions).takeLast(8)
    }
    fun generation() = revision
}
