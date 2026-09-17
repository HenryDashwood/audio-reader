package com.henrydashwood.magpie.voice

import java.util.UUID

/** In-memory, account/server-scoped context. Never stores microphone recordings. */
data class ConversationTurn(val speaker: String, val text: String) {
    init { require(speaker in setOf("her", "app")) }
}
data class VoiceRequest(val transcript: String, val requestId: String = UUID.randomUUID().toString(),
    val viewedEpisodeId: Int? = null, val nowPlayingEpisodeId: Int? = null,
    val turns: List<ConversationTurn> = emptyList(), val recentActions: List<String> = emptyList(),
    val country: String? = null) {
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

class Conversation(private val nowMillis: () -> Long = { System.nanoTime() / 1_000_000 }) {
    var owner: String? = null
        private set
    var turns: List<ConversationTurn> = emptyList()
        private set
    var pending: VoiceRequest? = null
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
        this.owner = owner; revision++
        clear(); pending = null; receipt = null; execution = null; recentActions = emptyList()
    }
    fun clear() { turns = emptyList(); lastSpoke = null }
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
        country: String? = null, recover: Boolean = false): VoiceRequest {
        forgetIfStale()
        require(transcript.isNotBlank() && transcript.length <= 2_000)
        if (recover && pending != null) { userSaid(transcript.trim()); return pending!! }
        val request = VoiceRequest(transcript.trim(), viewedEpisodeId = viewedEpisodeId,
            nowPlayingEpisodeId = playingEpisodeId, country = country,
            turns = turns.takeLast(8), recentActions = recentActions)
        userSaid(request.transcript)
        revision++; pending = request; receipt = null
        return request
    }
    fun confirmed(request: VoiceRequest, account: String?, response: VoiceResponse) {
        if (owner == account && pending?.requestId == request.requestId) receipt = response
    }
    /** Keep a receipt until its client-side effects have succeeded, including after cancellation. */
    fun applied(request: VoiceRequest, account: String?, actions: List<String>) {
        if (owner != account || pending?.requestId != request.requestId) return
        pending = null; receipt = null
        recentActions = (recentActions + actions).takeLast(8)
    }
    fun generation() = revision
}
