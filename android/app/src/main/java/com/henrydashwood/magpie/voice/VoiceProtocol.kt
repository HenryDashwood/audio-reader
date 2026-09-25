package com.henrydashwood.magpie.voice

import com.henrydashwood.magpie.data.RemoteEpisode
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.withTimeout
import java.io.Reader

class VoiceFailure(override val message: String, cause: Throwable? = null, val code: String? = null) : Exception(message, cause) {
    companion object {
        /** The server answered with a final refusal (HTTP 409). It stores one outcome per request ID. */
        const val REFUSED = "refused"
    }
}
enum class VoiceAction(val wire: String) {
    Play("play_episode"), Speed("set_speed"), Played("mark_played"), Dismiss("dismiss"), Restore("restore"),
    Subscribed("subscribed"), Unsubscribed("unsubscribed"), Unknown("unknown");
    companion object { fun decode(value: String) = entries.firstOrNull { it.wire == value } ?: Unknown }
}
data class ClarificationChoice(val id: String, val label: String)
data class VoiceClarification(val id: String, val question: String, val choices: List<ClarificationChoice>, val expiresAt: String)
data class VoiceResponse(val action: VoiceAction, val spokenResponse: String,
    val episode: RemoteEpisode? = null, val speed: Float? = null, val expectsReply: Boolean = false,
    val actions: List<VoiceResponse> = emptyList(), val status: String? = null, val clarification: VoiceClarification? = null) {
    val recoveryMessage: String get() = "Earlier result: $spokenResponse" +
        if (effects.any { it.action in setOf(VoiceAction.Play, VoiceAction.Speed) }) " Choose Play or a playback speed to continue now." else ""
    val effects: List<VoiceResponse> get() = if (actions.isEmpty()) listOf(this) else actions.flatMap { it.effects }
}
sealed interface VoiceEvent {
    data class Delta(val text: String) : VoiceEvent
    data class Result(val response: VoiceResponse) : VoiceEvent
}
/** A single request bound to its initiating session, including cancellation after sign-out. */
interface VoiceOperation {
    suspend fun response(onDelta: (String) -> Unit = {}): VoiceResponse
    suspend fun cancel()
}
interface VoiceApi {
    fun events(token: String, request: VoiceRequest): Flow<VoiceEvent>
    suspend fun cancel(token: String, requestId: String)
}

object VoiceExecution {
    const val UNCONFIRMED = "Magpie could not confirm how that request ended. Try again to check its result."
    suspend fun response(events: Flow<VoiceEvent>, onDelta: (String) -> Unit = {}): VoiceResponse = withTimeout(300_000) {
        var receipt: VoiceResponse? = null
        var characters = 0
        events.collect { event ->
            when (event) {
                is VoiceEvent.Delta -> {
                    characters += event.text.length
                    if (characters > 32_000 || receipt != null) throw VoiceFailure(UNCONFIRMED)
                    onDelta(event.text)
                }
                is VoiceEvent.Result -> {
                    if (receipt != null) throw VoiceFailure(UNCONFIRMED)
                    receipt = event.response
                }
            }
        }
        receipt ?: throw VoiceFailure(UNCONFIRMED)
    }
}

/** Bounded NDJSON framing; even an unterminated line cannot grow without limit. */
object VoiceLines {
    const val MAX_LINE = 512_000
    const val MAX_STREAM = 4_000_000
    fun read(reader: Reader, consume: (String) -> Unit) {
        val buffer = CharArray(4096)
        val line = StringBuilder()
        var total = 0
        while (true) {
            val count = reader.read(buffer)
            if (count < 0) break
            total += count
            if (total > MAX_STREAM) throw VoiceFailure(VoiceExecution.UNCONFIRMED)
            for (index in 0 until count) {
                val char = buffer[index]
                if (char == '\n') {
                    line.toString().trim().takeIf { it.isNotEmpty() }?.let(consume)
                    line.setLength(0)
                } else {
                    line.append(char)
                    if (line.length > MAX_LINE) throw VoiceFailure(VoiceExecution.UNCONFIRMED)
                }
            }
        }
        line.toString().trim().takeIf { it.isNotEmpty() }?.let(consume)
    }
}
