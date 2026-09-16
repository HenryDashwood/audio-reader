package com.henrydashwood.magpie.voice

import android.os.Bundle
import com.henrydashwood.magpie.data.*
import com.henrydashwood.magpie.playback.PlaybackService
import com.henrydashwood.magpie.playback.PlaybackStatus
import kotlinx.coroutines.CancellationException

class PlaybackVoiceHost(private val library: AccountLibrary, private val store: PreviewStore,
    private val playing: () -> LibraryItem?, private val prepare: () -> Unit,
    private val send: suspend (String, Bundle) -> Bundle) : VoiceHost {
    private data class UndoSpeed(val revision: Int, val kind: ContentKind, val before: Float, val applied: Float)
    private var undo: UndoSpeed? = null
    private var interruptedKind: ContentKind? = null
    private fun playbackKind() = playing()?.kind ?: interruptedKind ?: ContentKind.Podcast
    override fun account() = library.state.value.let { VoiceAccount(it.owner, it.revision, it.live, playing()?.episodeId,
        java.util.Locale.getDefault().country.takeIf { country -> country.matches(Regex("[A-Za-z]{2}")) }) }
    override suspend fun begin(token: String, revision: Int) {
        interruptedKind = playing()?.kind
        prepare()
        send(PlaybackService.BEGIN_VOICE, Bundle().apply { putString("token", token); putInt("revision", revision) })
    }
    override suspend fun end(token: String, resume: Boolean) {
        send(PlaybackService.END_VOICE, Bundle().apply { putString("token", token); putBoolean("resume", resume) })
    }
    override fun valid(token: String, revision: Int) = library.state.value.revision == revision && PlaybackStatus.voiceToken.value == token
    private suspend fun control(token: String, action: String, fill: Bundle.() -> Unit = {}): Bundle {
        if (!valid(token, library.state.value.revision)) throw CancellationException("Playback changed")
        return send(PlaybackService.VOICE_CONTROL, Bundle().apply { putString("token", token); putString("action", action); fill() })
    }
    private suspend fun speed(token: String, rate: Float, kind: ContentKind = playbackKind()): String {
        val result = control(token, "speed") { putFloat("rate", rate); putString("kind", kind.name) }
        undo = UndoSpeed(library.state.value.revision, kind, result.getFloat("previous_rate"), rate)
        return "${rate.toString().removeSuffix(".0")} times speed."
    }
    override suspend fun local(command: LocalCommand, token: String): LocalVoiceResult? {
        if (command !is LocalCommand.Speed && command !is LocalCommand.AdjustSpeed && command != LocalCommand.Undo) undo = null
        return when (command) {
            LocalCommand.Pause -> { control(token, "pause"); LocalVoiceResult(end = true) }
            LocalCommand.Resume -> { control(token, "resume"); LocalVoiceResult(end = true) }
            is LocalCommand.Seek -> { control(token, "seek") { putLong("delta_ms", (command.seconds * 1000).toLong()) }; LocalVoiceResult(end = true) }
            is LocalCommand.Speed -> LocalVoiceResult(speed(token, command.rate))
            is LocalCommand.AdjustSpeed -> LocalVoiceResult(speed(token, (store.speed(playbackKind()) + command.delta).coerceIn(.5f, 2f)))
            is LocalCommand.Sleep -> {
                control(token, "sleep") { putLong(PlaybackService.SLEEP_DURATION_MS, command.minutes * 60_000L) }
                LocalVoiceResult("I will stop in ${command.minutes} ${if (command.minutes == 1) "minute" else "minutes"}.")
            }
            LocalCommand.CancelSleep -> { control(token, "cancel_sleep"); LocalVoiceResult("Sleep timer off.") }
            LocalCommand.Undo -> {
                val previous = undo?.takeIf { it.revision == library.state.value.revision && store.speed(it.kind) == it.applied }
                if (previous == null) null else {
                    speed(token, previous.before, previous.kind); undo = null; LocalVoiceResult("Playback speed restored.")
                }
            }
            LocalCommand.EndConversation -> null
        }
    }
    override suspend fun consent() = library.aiConsent()
    override suspend fun allowAI() { if (!library.setAIConsent(true)) throw VoiceFailure("Your choice could not be saved. Please try again.") }
    override fun operation(request: VoiceRequest, revision: Int): VoiceOperation {
        undo = null
        val operation = library.voiceOperation(request, revision)
        val token = PlaybackStatus.voiceToken.value ?: throw CancellationException("Playback changed")
        return object : VoiceOperation {
            override suspend fun response(onDelta: (String) -> Unit): VoiceResponse {
                control(token, "drain")
                return operation.response(onDelta)
            }
            override suspend fun cancel() = operation.cancel()
        }
    }
    override suspend fun reconcile(response: VoiceResponse, token: String, revision: Int) {
        var refresh = false
        for (effect in response.effects) {
            if (!valid(token, revision)) throw CancellationException("Playback changed")
            when (effect.action) {
                VoiceAction.Played, VoiceAction.Dismiss -> {
                    val item = library.acceptVoiceEpisode(checkNotNull(effect.episode), revision)
                    control(token, "file") { putString("id", item.id) }
                    refresh = true
                }
                VoiceAction.Restore -> {
                    val item = library.acceptVoiceEpisode(checkNotNull(effect.episode), revision)
                    control(token, "restore") { putString("id", item.id); putLong("position_ms", item.remotePositionMs) }
                    refresh = true
                }
                VoiceAction.Subscribed, VoiceAction.Unsubscribed -> refresh = true
                else -> Unit
            }
        }
        if (refresh) library.refresh()
    }
    override suspend fun apply(response: VoiceResponse, token: String, revision: Int): Boolean {
        var toPlay: RemoteEpisode? = null
        for (effect in response.effects) {
            if (!valid(token, revision)) throw CancellationException("Playback changed")
            when (effect.action) {
                VoiceAction.Play -> toPlay = checkNotNull(effect.episode)
                VoiceAction.Speed -> speed(token, checkNotNull(effect.speed), toPlay?.let { if (it.audioUrl.isNullOrBlank()) ContentKind.Article else ContentKind.Podcast } ?: playbackKind())
                VoiceAction.Played, VoiceAction.Dismiss -> if (toPlay?.id == effect.episode?.id) toPlay = null
                else -> Unit
            }
        }
        toPlay?.let { selected ->
            val adopted = library.acceptVoiceEpisode(selected, revision)
            val item = if (adopted.textLoaded) adopted else library.content(adopted.id)
            control(token, "play") { putString("id", item.id) }
        }
        return toPlay != null
    }
}
