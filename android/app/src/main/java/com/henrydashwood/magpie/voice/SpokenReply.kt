package com.henrydashwood.magpie.voice

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.withTimeoutOrNull
import java.util.UUID

interface ReplyEngine {
    val maxCharacters: Int
    fun speak(text: String, id: String, finished: (String, String?) -> Unit)
    fun close()
}

/** Completion means the final audio finished, not merely that synthesis was queued. */
class SpokenReply(private val open: suspend () -> ReplyEngine) {
    private var speaking = false

    suspend fun speak(text: String) {
        require(text.length <= 32_000)
        if (text.isBlank()) return
        check(!speaking) { "Magpie is already speaking." }
        speaking = true
        var engine: ReplyEngine? = null
        try {
            val voice = open().also { engine = it }
            val completed = withTimeoutOrNull(600_000) {
                chunks(text, voice.maxCharacters).forEach { chunk ->
                    val id = UUID.randomUUID().toString()
                    val done = CompletableDeferred<Unit>()
                    voice.speak(chunk, id) { completedId, error ->
                        if (id == completedId) {
                            if (error == null) done.complete(Unit)
                            else done.completeExceptionally(VoiceFailure(error))
                        }
                    }
                    // Long replies are split, but a stalled engine must never hold the session forever.
                    withTimeoutOrNull(180_000) { done.await(); true }
                        ?: throw VoiceFailure("The speaking voice stopped responding. Please try again.")
                }
                true
            }
            if (completed != true) throw VoiceFailure("The spoken reply took too long. Please try a shorter request.")
        } finally {
            try { engine?.close() } finally { speaking = false }
        }
    }

    companion object {
        internal fun chunks(text: String, maximum: Int): List<String> {
            require(maximum >= 2)
            val limit = minOf(maximum, 1_500)
            val result = mutableListOf<String>()
            var start = 0
            while (start < text.length) {
                var end = minOf(start + limit, text.length)
                if (end < text.length) {
                    val space = text.lastIndexOfAny(charArrayOf(' ', '\n', '\t'), end - 1)
                    if (space > start + limit / 2) end = space + 1
                    if (text[end - 1].isHighSurrogate() && text[end].isLowSurrogate()) end--
                }
                result += text.substring(start, end)
                start = end
            }
            return result
        }
    }
}
