package com.henrydashwood.magpie.voice

import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.util.UUID

/** A spoken account detail holds the same player as a conversation, without opening the microphone. */
class SpokenInformation(private val scope: CoroutineScope, private val host: VoiceHost,
    private val output: VoiceOutput, private val conversation: Conversation, private val report: (String) -> Unit) {
    private val mutable = MutableStateFlow(false)
    val speaking = mutable.asStateFlow()
    private var job: Job? = null
    private var token: String? = null
    private var acquired = false
    private var resume = true

    fun speak(text: String) {
        if (mutable.value) return
        val account = host.account()
        val id = UUID.randomUUID().toString()
        mutable.value = true; token = id; resume = true
        job = scope.launch {
            try {
                check(conversation.acquire(id)) { "Magpie is already handling a request. Let it finish first." }
                // Ending an unacquired token is harmless; setting this before the
                // suspension also releases a hold if cancellation races the reply.
                acquired = true
                host.begin(id, account.revision)
                if (!host.valid(id, account.revision)) throw CancellationException("Playback changed")
                output.speak(text)
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (failure: Exception) { report(failure.message ?: "The address could not be read aloud. Please try again.") }
            finally {
                if (acquired) withContext(NonCancellable) { withTimeoutOrNull(5_000) { runCatching { host.end(id, resume) } } }
                conversation.release(id)
                acquired = false; token = null; mutable.value = false
            }
        }
    }
    fun stop(resume: Boolean = true) { this.resume = resume; job?.cancel() }
    fun playbackChanged(held: String?) { if (acquired && token != held) stop(resume = false) }
}
