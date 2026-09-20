package com.henrydashwood.magpie.voice

import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import java.util.UUID
import com.henrydashwood.magpie.telemetry.*

interface VoiceInput {
    suspend fun availability(): RecognitionAvailability = RecognitionAvailability.Ready
    suspend fun requestModelDownload() { throw VoiceFailure("Open Android speech settings to download a recognition language.") }
    suspend fun listen(firstWordsMs: Long = 8_000, onReady: () -> Unit = {}, onPartial: (String) -> Unit = {}): String?
    fun finish()
}
fun interface VoiceOutput { suspend fun speak(text: String) }
data class VoiceAccount(val owner: String?, val revision: Int, val live: Boolean, val playingEpisodeId: Int?, val country: String? = null)
data class LocalVoiceResult(val reply: String = "", val end: Boolean = false)
interface VoiceHost {
    fun account(): VoiceAccount
    suspend fun begin(token: String, revision: Int)
    suspend fun end(token: String, resume: Boolean)
    fun valid(token: String, revision: Int): Boolean
    suspend fun local(command: LocalCommand, token: String): LocalVoiceResult?
    suspend fun consent(): Boolean
    suspend fun allowAI()
    suspend fun prepareRequest(request: VoiceRequest, token: String) {}
    fun operation(request: VoiceRequest, revision: Int): VoiceOperation
    suspend fun cancelRecovery(request: VoiceRequest, token: String, revision: Int) = operation(request, revision).cancel()
    suspend fun reconcile(response: VoiceResponse, token: String, revision: Int) {}
    suspend fun reconcileRecovered(response: VoiceResponse, token: String, revision: Int) = reconcile(response, token, revision)
    suspend fun apply(response: VoiceResponse, token: String, revision: Int): Boolean
}
enum class VoicePhase { Idle, Preparing, Listening, Thinking, Speaking, Consent }
data class VoiceSessionState(val visible: Boolean = false, val phase: VoicePhase = VoicePhase.Idle,
    val turns: List<ConversationTurn> = emptyList(), val heard: String = "", val reply: String = "",
    val error: String? = null, val recoverable: Boolean = false, val launchListening: String? = null,
    val recoveryRequests: List<VoiceRequest> = emptyList(), val clarification: VoiceClarification? = null) {
    val busy: Boolean get() = phase in setOf(VoicePhase.Preparing, VoicePhase.Listening, VoicePhase.Thinking, VoicePhase.Speaking)
}

/** Main-thread conversation orchestration. Every turn owns one service-side playback hold. */
class VoiceSession(private val scope: CoroutineScope, private val host: VoiceHost,
    private val input: VoiceInput, private val output: VoiceOutput,
    private val preferences: () -> ConversationPreferences,
    private val conversation: Conversation = Conversation(),
    private val telemetry: VoiceTelemetry = VoiceTelemetry.NONE) {
    private val mutable = MutableStateFlow(VoiceSessionState())
    val state = mutable.asStateFlow()
    private var job: Job? = null
    private var restoreJob: Job? = null
    private var version = 0
    private var accountKey: String? = null
    private var viewedId: Int? = null
    private var deferredTranscript: String? = null
    private data class Turn(val token: String, val version: Int, var acquired: Boolean = false,
        var resume: Boolean = true, var safeToResume: Boolean = true, var operation: VoiceOperation? = null)
    private var turn: Turn? = null

    fun activate() {
        val account = host.account()
        val key = "${account.revision}:${account.owner}:${account.live}"
        if (key == accountKey) return
        close(resume = false)
        accountKey = key; conversation.activate(key); deferredTranscript = null
        mutable.value = VoiceSessionState()
    }
    fun open(viewedEpisodeId: Int?, listenOnOpen: Boolean = false) {
        close()
        activate(); viewedId = viewedEpisodeId; conversation.forgetIfStale()
        mutable.value = VoiceSessionState(visible = true, turns = conversation.turns, recoverable = conversation.pending != null,
            launchListening = if (listenOnOpen) UUID.randomUUID().toString() else null, recoveryRequests = conversation.recoveryRequests, clarification = conversation.clarification)
        val account = host.account()
        if (conversation.durable && account.live && account.owner != null) {
            val id = version
            restoreJob = scope.launch {
                try {
                    conversation.restore(account.owner)
                    if (id == version && state.value.visible) publish()
                } catch (cancelled: CancellationException) { throw cancelled }
                catch (_: Exception) {
                    if (id == version) mutable.update { it.copy(error = "Saved requests could not be read. Playback controls still work.") }
                }
            }
        }
    }
    val microphoneRequestVersion: Int get() = version
    fun acceptsMicrophoneRequest(requestVersion: Int) = requestVersion == version && state.value.visible && !state.value.busy
    fun consumeLaunchListening(id: String): Boolean {
        if (!state.value.visible || state.value.launchListening != id) return false
        mutable.update { it.copy(launchListening = null) }
        return true
    }
    fun listen(autoFollowUp: Boolean = true, accessible: Boolean = false) {
        if (state.value.phase == VoicePhase.Listening) { input.finish(); return }
        start(null, autoFollowUp, accessible)
    }
    fun microphoneDenied(accessible: Boolean = false) {
        runCatching { telemetry.begin(host.account(), accessible, conversation.turns.size)?.apply {
            outcome = VoiceOutcome.PermissionDenied; finish()
        } }
    }
    fun choose(choice: ClarificationChoice) {
        if ((state.value.busy && state.value.phase != VoicePhase.Listening) || conversation.clarification?.choices?.contains(choice) != true) return
        start(choice.label, autoFollowUp = false, selectedOptionId = choice.id)
    }
    fun submit(text: String) { if (text.isNotBlank()) start(text.trim(), autoFollowUp = false) }
    fun continueRequest(request: VoiceHandoffs.Request) {
        open(null)
        if (request.recovering) retry() else submit(request.transcript)
    }
    fun retry() = start("try again", autoFollowUp = false)
    fun retryRequest(id: String) = start("try again", autoFollowUp = false, recoveryId = id)
    fun dismissRequest(id: String) = start("dismiss request", autoFollowUp = false, dismissId = id)
    fun allowAI() { deferredTranscript?.let { start(it, autoFollowUp = false, allowConsent = true) } }
    fun declineAI() {
        deferredTranscript = null
        mutable.update { it.copy(phase = VoicePhase.Idle, heard = "", error = "AI data sharing is off. Playback and sleep commands still work on this device.") }
    }
    fun playbackChanged(token: String?) {
        val active = turn ?: return
        if (active.acquired && active.token != token) close(resume = false)
    }
    fun background() {
        if (!state.value.visible) return
        close()
        mutable.update { it.copy(visible = true) }
    }
    fun close(resume: Boolean = true) {
        version++
        restoreJob?.cancel()
        turn?.let { current ->
            // Disposal/recreation may close again after an explicit no-resume interruption.
            current.resume = current.resume && resume
            current.operation?.let { operation -> scope.launch { runCatching { operation.cancel() } } }
        }
        job?.cancel()
        mutable.update { it.copy(visible = false, phase = VoicePhase.Idle, heard = "", reply = "", launchListening = null) }
    }

    private fun start(text: String?, autoFollowUp: Boolean, accessible: Boolean = false, allowConsent: Boolean = false, recoveryId: String? = null, dismissId: String? = null, selectedOptionId: String? = null) {
        if (!state.value.visible) return
        if (text != null && text.length > 2_000) {
            mutable.update { it.copy(error = "Please ask in a shorter sentence.") }; return
        }
        restoreJob?.cancel()
        val previous = job
        turn?.operation?.let { operation -> scope.launch { runCatching { operation.cancel() } } }
        previous?.cancel()
        val id = ++version
        mutable.update { it.copy(phase = VoicePhase.Preparing, error = null, heard = "", reply = "", launchListening = null) }
        job = scope.launch {
            previous?.join()
            if (id != version) return@launch
            val account = host.account()
            val active = Turn(UUID.randomUUID().toString(), id)
            fun beginAttempt() = runCatching { telemetry.begin(account, accessible, conversation.turns.size) }.getOrNull()
            var attempt = if (text == null) beginAttempt() else null
            turn = active
            fun checkTurn() {
                if (id != version || !host.valid(active.token, account.revision)) throw CancellationException("Conversation interrupted")
            }
            try {
                check(conversation.acquire(active.token)) { "Magpie is already handling a request. Let it finish and try again." }
                host.begin(active.token, account.revision); active.acquired = true; checkTurn()
                if (allowConsent) { host.allowAI(); checkTurn(); deferredTranscript = null }
                if (dismissId != null) {
                    val owner = checkNotNull(account.owner)
                    conversation.restore(owner); checkTurn()
                    conversation.selectRecovery(dismissId)
                    val request = checkNotNull(conversation.pending)
                    active.safeToResume = false
                    host.prepareRequest(request, active.token); checkTurn()
                    host.cancelRecovery(request, active.token, account.revision); checkTurn()
                    conversation.complete(request, conversation.owner, emptyList(), owner)
                    checkTurn(); active.safeToResume = true
                    conversation.appSaid("Request removed from unfinished requests. Any library changes already made remain.")
                    return@launch
                }
                var supplied = text
                var followUp = false
                while (true) {
                    if (followUp) attempt = beginAttempt()
                    mutable.update { it.copy(phase = VoicePhase.Preparing, heard = "", reply = "") }
                    if (supplied == null) attempt?.listening()
                    val heard = (supplied ?: input.listen(
                        firstWordsMs = if (followUp) preferences().followUpSeconds * 1_000L else if (accessible) 15_000 else 8_000,
                        onReady = { checkTurn(); mutable.update { it.copy(phase = VoicePhase.Listening) } },
                        onPartial = { caption -> checkTurn(); mutable.update { it.copy(heard = caption) } },
                    )).orEmpty().trim()
                    supplied = null
                    attempt?.captured(heard.isEmpty())
                    checkTurn()
                    if (heard.isEmpty()) {
                        attempt?.outcome = VoiceOutcome.NoSpeech
                        if (!followUp) mutable.update { it.copy(error = "I did not hear anything. Tap Listen to try again.") }
                        break
                    }
                    mutable.update { it.copy(phase = VoicePhase.Thinking, heard = heard) }
                    val command = if (selectedOptionId == null) LocalCommand.match(heard) else null
                    if (command == LocalCommand.EndConversation) {
                        conversation.abandonClarification()
                        attempt?.local(command)
                        conversation.userSaid(heard); publish(); mutable.update { it.copy(visible = false) }; break
                    }
                    val local = command?.let { host.local(it, active.token) }
                    var expectsReply = false
                    if (local != null) {
                        conversation.abandonClarification()
                        attempt?.local(checkNotNull(command)); attempt?.answered()
                        conversation.userSaid(heard); publish()
                        say(local.reply, ::checkTurn)
                        if (local.end) { mutable.update { it.copy(visible = false) }; break }
                    } else {
                        if (!account.live) throw VoiceFailure("Sign in to ask about your library. Playback and sleep commands work without an account.")
                        val owner = checkNotNull(account.owner)
                        conversation.restore(owner); checkTurn()
                        recoveryId?.let(conversation::selectRecovery)
                        val recovering = heard.lowercase(java.util.Locale.ROOT).trimEnd('.', '?', '!') in setOf("try again", "did that work", "what happened", "check that request")
                        val typedRecovery = recovering && conversation.pending?.let { conversation.structured(it.requestId) } != null
                        val undo = command == LocalCommand.Undo
                        if (!typedRecovery && !undo && !host.consent()) {
                            checkTurn(); deferredTranscript = heard
                            attempt?.outcome = VoiceOutcome.ConsentRequired
                            mutable.update { it.copy(phase = VoicePhase.Consent) }; break
                        }
                        checkTurn()
                        val request = if (undo) conversation.unfinished("undo")?.also { conversation.selectRecovery(it.requestId) }
                            ?: conversation.structuredRequest(StructuredLibraryRequest("undo", null), "Undo the last library change")
                        else conversation.request(heard, viewedId, account.playingEpisodeId, country = account.country, recover = recovering, selectedOptionId = selectedOptionId)
                        publish()
                        active.safeToResume = false
                        conversation.persist(owner); checkTurn()
                        host.prepareRequest(request, active.token); checkTurn()
                        val response = conversation.receipt ?: run {
                            val operation = host.operation(request, account.revision)
                            active.operation = operation
                            attempt?.sent(request.requestId)
                            operation.response { delta -> checkTurn(); mutable.update { it.copy(reply = it.reply + delta) } }
                                .also { conversation.confirmed(request, accountKey, it) }
                        }
                        active.operation = null; checkTurn(); attempt?.answered()
                        conversation.persist(owner); checkTurn()
                        // These effects already happened on the server, even if confirmation is cancelled.
                        val restored = conversation.wasRestored(request.requestId)
                        if (restored) host.reconcileRecovered(response, active.token, account.revision)
                        else host.reconcile(response, active.token, account.revision)
                        checkTurn()
                        active.safeToResume = true
                        say(if (restored) response.recoveryMessage else response.spokenResponse, ::checkTurn)
                        val playing = !restored && host.apply(response, active.token, account.revision)
                        conversation.complete(request, conversation.owner, response.effects.map {
                            "${it.action.wire}: ${it.spokenResponse}" + (it.episode?.let { row -> " [episode_id=${row.id}]" } ?: "")
                        }, owner)
                        checkTurn()
                        publish(); expectsReply = response.expectsReply
                        attempt?.outcome = if (playing) VoiceOutcome.Played else VoiceOutcome.Spoken
                        if (playing) { mutable.update { it.copy(visible = false) }; break }
                    }
                    if (!autoFollowUp || accessible || (!preferences().keepListening && !expectsReply)) break
                    attempt?.finish(); attempt = null
                    followUp = true
                }
            } catch (_: TimeoutCancellationException) {
                attempt?.outcome = VoiceOutcome.Timeout
                if (id == version) mutable.update { it.copy(error = "That request took too long. Please try again to check its result.") }
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (failure: Exception) {
                attempt?.outcome = if (failure is VoiceFailure && failure.code == "permission_denied") VoiceOutcome.PermissionDenied else VoiceOutcome.Error
                if (id == version) mutable.update { it.copy(error = failure.message ?: "That request could not finish. Please try again.") }
            } finally {
                attempt?.finish()
                if (turn === active) turn = null
                if (active.acquired) withContext(NonCancellable) { withTimeoutOrNull(5_000) { runCatching { host.end(active.token, active.resume && active.safeToResume) } } }
                conversation.release(active.token)
                if (id == version) {
                    publish()
                    mutable.update { it.copy(phase = if (it.phase == VoicePhase.Consent) VoicePhase.Consent else VoicePhase.Idle, heard = if (it.phase == VoicePhase.Consent) it.heard else "") }
                }
            }
        }
    }

    private suspend fun say(text: String, checkTurn: () -> Unit) {
        if (text.isBlank()) return
        conversation.appSaid(text); publish()
        mutable.update { it.copy(phase = VoicePhase.Speaking, reply = "") }
        output.speak(text); checkTurn()
    }
    private fun publish() { mutable.update { it.copy(turns = conversation.turns, heard = if (it.phase == VoicePhase.Consent) it.heard else "", recoverable = conversation.pending != null, recoveryRequests = conversation.recoveryRequests, clarification = conversation.clarification) } }
}
