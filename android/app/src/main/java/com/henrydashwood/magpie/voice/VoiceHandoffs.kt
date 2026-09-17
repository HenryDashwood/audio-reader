package com.henrydashwood.magpie.voice

import java.util.UUID

/** Private, one-use continuation capabilities. Intents carry only an opaque ID. */
class VoiceHandoffs(private val now: () -> Long = { System.nanoTime() / 1_000_000 }) {
    data class Request(val transcript: String, val recovering: Boolean)
    private data class Entry(val owner: String, val generation: Int, val requestId: String?, val request: Request, val expires: Long)
    private val entries = linkedMapOf<String, Entry>()
    fun clear() = entries.clear()
    fun create(owner: String, generation: Int, transcript: String, requestId: String? = null): String {
        require(transcript.isNotBlank() && transcript.length <= 2_000)
        entries.entries.removeAll { it.value.expires <= now() }
        while (entries.size >= 16) entries.remove(entries.keys.first())
        val id = UUID.randomUUID().toString()
        entries[id] = Entry(owner, generation, requestId, Request(transcript, requestId != null), now() + 600_000)
        return id
    }
    fun consume(id: String, owner: String, generation: Int, pendingId: String?): Request {
        val entry = entries.remove(id)
        check(entry != null && entry.owner == owner && entry.generation == generation && entry.expires > now() &&
            (entry.requestId == null || entry.requestId == pendingId)) { "That request is no longer available. Open Ask Magpie to continue." }
        return entry.request
    }
}
