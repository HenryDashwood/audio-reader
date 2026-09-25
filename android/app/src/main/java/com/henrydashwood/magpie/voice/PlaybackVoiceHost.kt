package com.henrydashwood.magpie.voice

import android.os.Bundle
import com.henrydashwood.magpie.data.*
import com.henrydashwood.magpie.playback.PlaybackService
import com.henrydashwood.magpie.playback.PlaybackStatus
import kotlinx.coroutines.CancellationException

class PlaybackVoiceHost(private val library: AccountLibrary, private val store: PreviewStore,
    private val playing: () -> LibraryItem?, private val prepare: () -> Unit,
    private val send: suspend (String, Bundle) -> Bundle,
    private val startPlayback: (suspend (LibraryItem) -> Unit)? = null,
    private val resetRestoredBookmark: Boolean = false) : VoiceHost {
    private var interruptedKind: ContentKind? = null
    private var requestId: String? = null
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
    suspend fun drain(token: String, requestId: String) {
        this.requestId = requestId
        control(token, "drain") { putString("request_id", requestId) }
    }
    override suspend fun prepareRequest(request: VoiceRequest, token: String) = drain(token, request.requestId)
    private suspend fun speed(token: String, rate: Float, kind: ContentKind = playbackKind()): String {
        control(token, "speed") { putFloat("rate", rate); putString("kind", kind.name) }
        return "${rate.toString().removeSuffix(".0")} times speed."
    }
    override suspend fun local(command: LocalCommand, token: String): LocalVoiceResult? {
        return when (command) {
            LocalCommand.Pause -> { control(token, "pause"); LocalVoiceResult(end = true) }
            LocalCommand.Resume -> { control(token, "resume"); LocalVoiceResult(end = true) }
            is LocalCommand.Seek -> { control(token, "seek") { putLong("delta_ms", (command.seconds * 1000).toLong()) }; LocalVoiceResult(end = true) }
            is LocalCommand.Speed -> LocalVoiceResult(speed(token, command.rate))
            // As on iOS: quarter steps, "faster" stops at 2× and "slower" at 0.5×.
            is LocalCommand.AdjustSpeed -> LocalVoiceResult(speed(token, (store.speed(playbackKind()) + command.delta).let {
                if (command.delta > 0) it.coerceAtMost(2f) else it.coerceAtLeast(.5f) }))
            is LocalCommand.Sleep -> {
                control(token, "sleep") { putLong(PlaybackService.SLEEP_DURATION_MS, command.minutes * 60_000L) }
                LocalVoiceResult("I will stop in ${command.minutes} ${if (command.minutes == 1) "minute" else "minutes"}.")
            }
            LocalCommand.CancelSleep -> { control(token, "cancel_sleep"); LocalVoiceResult("Sleep timer off.") }
            LocalCommand.Undo -> {
                val previous = library.speedUndo?.takeIf { it.revision == library.state.value.revision &&
                    it.owner == library.state.value.owner && android.os.SystemClock.elapsedRealtime() < it.expiresAt }
                if (previous != null && store.speed(previous.kind) != previous.after) {
                    library.speedUndo = null
                    return LocalVoiceResult("Playback speed has changed since then. I left it as it is.")
                }
                if (previous == null) null else {
                    speed(token, previous.before, previous.kind); library.speedUndo = null; LocalVoiceResult("Playback speed restored.")
                }
            }
            LocalCommand.EndConversation -> null
        }
    }
    override suspend fun consent() = library.aiConsent()
    override suspend fun allowAI() { if (!library.setAIConsent(true)) throw VoiceFailure("Your choice could not be saved. Please try again.") }
    override fun operation(request: VoiceRequest, revision: Int): VoiceOperation {
        library.speedUndo = null
        return library.voiceOperation(request, revision)
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
                    control(token, "restore") {
                        putString("id", item.id); putLong("position_ms", item.remotePositionMs)
                        putBoolean("reset_bookmark", resetRestoredBookmark)
                    }
                    // Explicit unread/unplayed starts over. Undo keeps its
                    // original bookmark through the default reconciliation path.
                    if (resetRestoredBookmark) control(token, "file") { putString("id", item.id) }
                    refresh = true
                }
                VoiceAction.Subscribed, VoiceAction.Unsubscribed -> refresh = true
                else -> Unit
            }
        }
        if (refresh) library.refresh()
        requestId?.let { id -> control(token, "confirm") { putString("request_id", id) }; requestId = null }
    }
    override suspend fun cancelRecovery(request: VoiceRequest, token: String, revision: Int) {
        if (!valid(token, revision)) throw CancellationException("Playback changed")
        library.voiceOperation(request, revision).cancel()
        if (!valid(token, revision)) throw CancellationException("Playback changed")
        library.refresh()
        library.state.value.error?.let { throw VoiceFailure(it) }
        if (!valid(token, revision)) throw CancellationException("Playback changed")
        keepFiledPlaybackPaused(token)
        control(token, "confirm") { putString("request_id", request.requestId) }
        requestId = null
    }

    override suspend fun reconcileRecovered(response: VoiceResponse, token: String, revision: Int) {
        // A receipt can be days old. Reconcile current server state without
        // replaying old filing/bookmark/player effects over newer user intent.
        for (id in response.effects.mapNotNull { it.episode?.id }.distinct()) {
            if (!valid(token, revision)) throw CancellationException("Playback changed")
            try { library.recoverVoiceEpisode(id, revision) }
            catch (failure: com.henrydashwood.magpie.auth.AccountFailure) {
                if (failure.status != 404) throw failure
            }
        }
        if (response.effects.any { it.action in setOf(VoiceAction.Played, VoiceAction.Dismiss, VoiceAction.Restore, VoiceAction.Subscribed, VoiceAction.Unsubscribed) }) {
            library.refresh()
            library.state.value.error?.let { throw VoiceFailure(it) }
        }
        if (!valid(token, revision)) throw CancellationException("Playback changed")
        keepFiledPlaybackPaused(token)
        requestId?.let { id -> control(token, "confirm") { putString("request_id", id) }; requestId = null }
    }

    private suspend fun keepFiledPlaybackPaused(token: String) {
        // Recovery can discover that the interrupted item was filed elsewhere.
        // Do not automatically resume its old clock (including on legacy servers).
        // Preserve bookmarks and let a later explicit Play establish new intent.
        if (playing()?.let { it.completed || it.dismissed } == true) control(token, "pause")
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
            if (startPlayback != null) startPlayback.invoke(adopted)
            else {
                val item = if (adopted.textLoaded) adopted else library.content(adopted.id)
                control(token, "play") { putString("id", item.id) }
            }
        }
        return toPlay != null
    }
}
