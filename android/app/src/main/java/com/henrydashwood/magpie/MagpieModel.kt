package com.henrydashwood.magpie

import android.app.Application
import android.content.ComponentName
import android.os.Bundle
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import androidx.media3.common.Player
import androidx.media3.session.MediaController
import androidx.media3.session.SessionCommand
import androidx.media3.session.SessionToken
import com.henrydashwood.magpie.data.ContentKind
import com.henrydashwood.magpie.data.LinkInbox
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.withContext
import com.henrydashwood.magpie.playback.VoiceCatalog
import kotlinx.coroutines.Job
import com.henrydashwood.magpie.data.LibraryItem
import com.henrydashwood.magpie.data.PreviewStore
import com.henrydashwood.magpie.data.SampleLibrary
import com.henrydashwood.magpie.playback.PlaybackService
import com.henrydashwood.magpie.playback.PlaybackStatus
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

data class PlayerState(
    val item: LibraryItem? = null,
    val playing: Boolean = false,
    val buffering: Boolean = false,
    val positionMs: Long = 0,
    val durationMs: Long = 0,
    val speed: Float = 1f,
    val connected: Boolean = false,
)

data class ListeningSettings(val podcastSpeed: Float, val articleSpeed: Float, val voiceId: String?)
data class LinkCaptureState(val showing: Boolean = false, val url: String = "", val saving: Boolean = false, val error: String? = null, val savedUrl: String? = null)

class MagpieModel(application: Application) : AndroidViewModel(application) {
    val library = SampleLibrary().items
    private val store = PreviewStore(application)
    private val mutableDismissedFromLatest = MutableStateFlow(store.dismissedFromLatest)
    val dismissedFromLatest = mutableDismissedFromLatest.asStateFlow()
    private val mutableClearingLatest = MutableStateFlow(false)
    val clearingLatest = mutableClearingLatest.asStateFlow()
    private val mutableClearLatestError = MutableStateFlow<String?>(null)
    val clearLatestError = mutableClearLatestError.asStateFlow()
    private val sourceInbox = LinkInbox(application, "magpie_source_inbox")
    private val mutablePendingSources = MutableStateFlow(sourceInbox.links())
    val pendingSources = mutablePendingSources.asStateFlow()
    private val mutableSourceCapture = MutableStateFlow(LinkCaptureState())
    val sourceCapture = mutableSourceCapture.asStateFlow()
    private val inbox = LinkInbox(application)
    private val mutablePendingLinks = MutableStateFlow(inbox.links())
    val pendingLinks = mutablePendingLinks.asStateFlow()
    private val mutableLinkCapture = MutableStateFlow(LinkCaptureState())
    val linkCapture = mutableLinkCapture.asStateFlow()
    private val mutableSaved = MutableStateFlow(store.saved)
    val saved = mutableSaved.asStateFlow()
    private val mutableFinished = MutableStateFlow(store.finished)
    val finished = mutableFinished.asStateFlow()
    private val mutablePlayer = MutableStateFlow(PlayerState(item = library.find { it.id == store.lastItem }, speed = store.speed(library.find { it.id == store.lastItem }?.kind ?: ContentKind.Podcast)))
    val player = mutablePlayer.asStateFlow()
    private fun readSettings() = ListeningSettings(store.speed(ContentKind.Podcast), store.speed(ContentKind.Article), store.voiceId)
    private val mutableSettings = MutableStateFlow(readSettings())
    val settings = mutableSettings.asStateFlow()
    private val voiceCatalog = VoiceCatalog(application)
    val voices = voiceCatalog.state
    private var voiceRefresh: Job? = null
    val preparation = PlaybackStatus.state
    val sleepTimer = PlaybackStatus.sleepTimer
    private val mutableNotice = MutableStateFlow<String?>(null)
    val notice = mutableNotice.asStateFlow()
    private var controller: MediaController? = null
    private val connection = MediaController.Builder(application, SessionToken(application, ComponentName(application, PlaybackService::class.java))).buildAsync()

    init {
        connection.addListener({
            try {
                controller = connection.get().also { media ->
                    media.addListener(object : Player.Listener {
                        override fun onEvents(player: Player, events: Player.Events) { updatePlayer() }
                    })
                }
                updatePlayer()
            } catch (_: Exception) { mutableNotice.value = "The player could not connect. Close and reopen Magpie to try again." }
        }, application.mainExecutor)
        viewModelScope.launch { while (isActive) { delay(500); updatePlayer() } }
    }

    private fun updatePlayer() {
        mutableSettings.value = readSettings()
        // Playback can finish in the service while the activity is backgrounded.
        mutableFinished.value = store.finished
        val media = controller ?: return
        mutablePlayer.value = PlayerState(
            item = library.find { it.id == (preparation.value.itemId ?: media.currentMediaItem?.mediaId ?: store.lastItem) },
            playing = media.isPlaying,
            buffering = media.playbackState == Player.STATE_BUFFERING,
            positionMs = media.currentPosition.coerceAtLeast(0),
            durationMs = media.duration.coerceAtLeast(0),
            speed = media.playbackParameters.speed,
            connected = media.isConnected,
        )
    }

    fun play(item: LibraryItem) {
        voiceCatalog.stop()
        val media = controller
        if (media == null || !media.isConnected) { mutableNotice.value = "The player is still connecting. Please try again."; return }
        mutablePlayer.update { it.copy(item = item) }
        val result = media.sendCustomCommand(SessionCommand(PlaybackService.PLAY_ITEM, Bundle.EMPTY), Bundle().apply { putString("id", item.id) })
        result.addListener({
            try { if (result.get().resultCode < 0) mutableNotice.value = "The player could not open this item. Please try again." }
            catch (_: Exception) { mutableNotice.value = "The player disconnected. Please try again." }
        }, getApplication<Application>().mainExecutor)
    }

    fun toggle() {
        if (player.value.playing) controller?.pause() else player.value.item?.let(::play)
    }
    fun pause() {
        if (preparation.value.message != null) cancelPreparation()
        controller?.pause()
    }
    fun skip(seconds: Int) { seek(player.value.positionMs + seconds * 1000L) }
    fun seek(positionMs: Long) {
        if (player.value.durationMs > 0) controller?.seekTo(positionMs.coerceIn(0, player.value.durationMs))
    }
    fun speed(value: Float) = setSpeed(player.value.item?.kind ?: ContentKind.Podcast, value)
    fun setSpeed(kind: ContentKind, value: Float) {
        store.saveSpeed(kind, value)
        mutableSettings.value = readSettings()
        val loadedKind = library.find { it.id == controller?.currentMediaItem?.mediaId }?.kind
        if (loadedKind == kind) {
            controller?.setPlaybackSpeed(value)
            mutablePlayer.update { it.copy(speed = value) }
        }
    }
    fun selectVoice(id: String?) {
        voiceCatalog.stop()
        store.voiceId = id
        mutableSettings.value = readSettings()
    }
    fun refreshVoices() {
        val previous = voiceRefresh
        previous?.cancel()
        voiceRefresh = viewModelScope.launch { previous?.join(); voiceCatalog.refresh() }
    }
    fun previewVoice() {
        pause()
        voiceCatalog.preview(store.voiceId, store.speed(ContentKind.Article))
    }
    fun stopVoicePreview() = voiceCatalog.stop()
    fun closeVoiceSettings() { voiceRefresh?.cancel(); voiceCatalog.close() }
    fun cancelPreparation() {
        controller?.sendCustomCommand(SessionCommand(PlaybackService.CANCEL_PREPARATION, Bundle.EMPTY), Bundle.EMPTY)
    }
    fun dismissPlayer() {
        voiceCatalog.stop()
        val media = controller
        if (media == null || !media.isConnected) {
            mutableNotice.value = "The player is still connecting. Please try again."
            return
        }
        val result = media.sendCustomCommand(SessionCommand(PlaybackService.DISMISS_PLAYER, Bundle.EMPTY), Bundle.EMPTY)
        result.addListener({
            try {
                if (result.get().resultCode < 0) mutableNotice.value = "The player could not be closed. Please try again."
                else updatePlayer()
            } catch (_: Exception) { mutableNotice.value = "The player disconnected. Please try again." }
        }, getApplication<Application>().mainExecutor)
    }

    fun startSleepTimer(minutes: Int) = changeSleepTimer(PlaybackService.SET_SLEEP_TIMER,
        Bundle().apply { putLong(PlaybackService.SLEEP_DURATION_MS, minutes * 60_000L) })

    fun cancelSleepTimer() = changeSleepTimer(PlaybackService.CANCEL_SLEEP_TIMER, Bundle.EMPTY)

    private fun changeSleepTimer(action: String, args: Bundle) {
        val media = controller
        if (media == null || !media.isConnected) {
            mutableNotice.value = "The player is still connecting. Please try again."
            return
        }
        val result = media.sendCustomCommand(SessionCommand(action, Bundle.EMPTY), args)
        result.addListener({
            try {
                if (result.get().resultCode < 0) mutableNotice.value = "The sleep timer could not be changed. Please try again."
            } catch (_: Exception) { mutableNotice.value = "The player disconnected. Please try again." }
        }, getApplication<Application>().mainExecutor)
    }
    fun toggleSaved(item: LibraryItem) {
        val next = if (item.id in saved.value) saved.value - item.id else saved.value + item.id
        store.saved = next
        mutableSaved.value = next
        mutableNotice.value = if (item.id in next) "Saved for later" else "Removed from Saved"
    }
    fun dismissNotice() { mutableNotice.value = null }

    fun clearLatest() {
        if (mutableClearingLatest.value) return
        mutableClearingLatest.value = true
        mutableClearLatestError.value = null
        val currentIds = library.map { it.id }.toSet()
        viewModelScope.launch {
            try {
                val dismissed = withContext(Dispatchers.IO) { store.dismissFromLatest(currentIds) }
                mutableDismissedFromLatest.value = dismissed
                mutableNotice.value = "Latest cleared"
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (error: Exception) { mutableClearLatestError.value = error.message ?: "Latest could not be cleared. Please try again." }
            finally { mutableClearingLatest.value = false }
        }
    }
    fun dismissClearLatestError() { mutableClearLatestError.value = null }

    fun beginLinkCapture() { mutableLinkCapture.update { it.copy(showing = true, error = null) } }
    fun closeLinkCapture() { mutableLinkCapture.update { if (it.saving) it else it.copy(showing = false) } }
    fun editLink(url: String) { mutableLinkCapture.update { if (it.saving) it else it.copy(url = url, error = null) } }
    fun acknowledgeSavedLink() { mutableLinkCapture.update { it.copy(savedUrl = null) } }
    fun saveLink() {
        val capture = mutableLinkCapture.value
        if (capture.saving) return
        mutableLinkCapture.value = capture.copy(saving = true, error = null)
        viewModelScope.launch {
            try {
                val added = withContext(Dispatchers.IO) { inbox.add(capture.url) }
                mutablePendingLinks.value = inbox.links()
                mutableLinkCapture.value = LinkCaptureState(savedUrl = capture.url)
                mutableNotice.value = if (added) "Link saved on this device" else "This link is already saved on this device"
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (error: Exception) { mutableLinkCapture.update { it.copy(saving = false, error = error.message ?: "The link could not be saved. Please try again.") } }
        }
    }
    fun removePendingLink(url: String) {
        viewModelScope.launch {
            try {
                withContext(Dispatchers.IO) { inbox.remove(url) }
                mutablePendingLinks.value = inbox.links()
                mutableNotice.value = "Saved link removed"
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (error: Exception) { mutableNotice.value = error.message ?: "The link could not be removed. Please try again." }
        }
    }

    fun beginSourceCapture() { mutableSourceCapture.update { it.copy(showing = true, error = null) } }
    fun closeSourceCapture() { mutableSourceCapture.update { if (it.saving) it else it.copy(showing = false) } }
    fun editSource(url: String) { mutableSourceCapture.update { if (it.saving) it else it.copy(url = url, error = null) } }
    fun acknowledgeSavedSource() { mutableSourceCapture.update { it.copy(savedUrl = null) } }
    fun saveSource() {
        val capture = mutableSourceCapture.value
        if (capture.saving) return
        mutableSourceCapture.value = capture.copy(saving = true, error = null)
        viewModelScope.launch {
            try {
                val added = withContext(Dispatchers.IO) { sourceInbox.add(capture.url) }
                mutablePendingSources.value = sourceInbox.links()
                mutableSourceCapture.value = LinkCaptureState(savedUrl = capture.url)
                mutableNotice.value = if (added) "Feed address saved on this device" else "This feed address is already saved on this device"
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (error: Exception) { mutableSourceCapture.update { it.copy(saving = false, error = error.message ?: "The link could not be saved. Please try again.") } }
        }
    }
    fun removePendingSource(url: String) {
        viewModelScope.launch {
            try {
                withContext(Dispatchers.IO) { sourceInbox.remove(url) }
                mutablePendingSources.value = sourceInbox.links()
                mutableNotice.value = "Feed address removed"
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (error: Exception) { mutableNotice.value = error.message ?: "The link could not be removed. Please try again." }
        }
    }

    fun toggleFinished(item: LibraryItem) {
        val next = if (item.id in finished.value) finished.value - item.id else finished.value + item.id
        store.finished = next
        mutableFinished.value = next
        mutableNotice.value = if (item.id in next) "Marked as read: ${item.title}" else "Marked as unread: ${item.title}"
    }

    override fun onCleared() {
        closeVoiceSettings()
        MediaController.releaseFuture(connection)
    }
}
