package com.henrydashwood.magpie.voice

import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.withTimeoutOrNull

sealed interface RecognitionEvent {
    data object Ready : RecognitionEvent
    data object Beginning : RecognitionEvent
    data class Partial(val text: String) : RecognitionEvent
    data class Final(val text: String) : RecognitionEvent
    data object End : RecognitionEvent
    data object Silence : RecognitionEvent
    data class Failed(val message: String) : RecognitionEvent
    data object Finish : RecognitionEvent
}

/** One native recognizer per capture. All calls and callbacks belong to its owner thread. */
interface RecognitionEngine {
    fun start(emit: (RecognitionEvent) -> Unit)
    fun finish()
    fun close()
}

/** Partials are captions only. Only an engine's final result can execute a command. */
class SpeechCapture(private val nowMillis: () -> Long = { System.nanoTime() / 1_000_000 }) {
    private var events: Channel<RecognitionEvent>? = null

    fun finish() { events?.trySend(RecognitionEvent.Finish) }

    suspend fun listen(engine: RecognitionEngine, firstWordsMs: Long = 8_000,
        onReady: () -> Unit = {}, onPartial: (String) -> Unit = {}): String? {
        require(firstWordsMs in 1_000..30_000)
        if (events != null) { engine.close(); throw VoiceFailure("The microphone is already listening.") }
        val queue = Channel<RecognitionEvent>(64)
        events = queue
        try {
            engine.start { event ->
                if (queue.trySend(event).isFailure) queue.close(VoiceFailure("Speech recognition could not keep up. Please try again."))
            }
            val result = withTimeoutOrNull(120_000) { capture(queue, engine, firstWordsMs, onReady, onPartial) to true }
                ?: throw VoiceFailure("The listening session was too long. Please try a shorter request.")
            return result.first
        } finally {
            events = null
            queue.close()
            engine.close()
        }
    }

    private suspend fun capture(queue: Channel<RecognitionEvent>, engine: RecognitionEngine,
        firstWordsMs: Long, onReady: () -> Unit, onPartial: (String) -> Unit): String? {
        var ready = false
        var heardSpeech = false
        var finishing = false
        var lastPartial = ""
        var deadline = nowMillis() + 10_000 // Startup is distinct from the time allowed to speak.
        while (true) {
            val event = withTimeoutOrNull((deadline - nowMillis()).coerceAtLeast(1)) { queue.receive() }
            if (event == null) {
                if (finishing || !ready) throw VoiceFailure("Speech recognition stopped responding. Please try again.")
                if (!heardSpeech) return null
                finishing = true; engine.finish(); deadline = nowMillis() + 5_000
                continue
            }
            when (event) {
                RecognitionEvent.Ready -> if (!ready && !finishing) {
                    ready = true; deadline = nowMillis() + firstWordsMs; onReady()
                }
                RecognitionEvent.Beginning -> if (!finishing && !heardSpeech) {
                    heardSpeech = true; deadline = nowMillis() + 30_000
                }
                is RecognitionEvent.Partial -> if (!finishing) {
                    val text = transcript(event.text)
                    if (text != lastPartial) {
                        lastPartial = text; onPartial(text)
                        if (text.isNotBlank()) { heardSpeech = true; deadline = nowMillis() + 2_500 }
                    }
                }
                is RecognitionEvent.Final -> return transcript(event.text).takeIf { it.isNotBlank() }
                RecognitionEvent.End -> if (!finishing) { finishing = true; deadline = nowMillis() + 5_000 }
                RecognitionEvent.Finish -> if (!finishing) { finishing = true; engine.finish(); deadline = nowMillis() + 5_000 }
                RecognitionEvent.Silence -> return null
                is RecognitionEvent.Failed -> throw VoiceFailure(event.message)
            }
        }
    }

    private fun transcript(text: String): String {
        val trimmed = text.trim()
        if (trimmed.length > 2_000) throw VoiceFailure("That was too long for one request. Please ask in a shorter sentence.")
        return trimmed
    }
}

/** Some on-device engines end silence before the chosen follow-up window has elapsed. */
class SpeechInputWindow(private val nowMillis: () -> Long = { System.nanoTime() / 1_000_000 }) {
    private val capture = SpeechCapture(nowMillis)
    private var finished = false
    fun finish() { finished = true; capture.finish() }
    suspend fun listen(create: () -> RecognitionEngine, firstWordsMs: Long,
        onReady: () -> Unit, onPartial: (String) -> Unit): String? {
        require(firstWordsMs in 1_000..30_000)
        finished = false
        var deadline: Long? = null
        var heardWords = false
        while (true) {
            val remaining = deadline?.let { it - nowMillis() } ?: firstWordsMs
            if (finished || remaining < 1_000) return null
            val result = capture.listen(create(), remaining.coerceAtMost(30_000), onReady = {
                if (deadline == null) { deadline = nowMillis() + firstWordsMs; onReady() }
            }, onPartial = {
                heardWords = heardWords || it.isNotBlank(); onPartial(it)
            })
            if (result != null || finished || heardWords || deadline == null) return result
            delay(250) // Avoid hammering a recognizer that reports silence immediately.
        }
    }
}
