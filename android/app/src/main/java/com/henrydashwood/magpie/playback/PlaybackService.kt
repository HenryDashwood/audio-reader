package com.henrydashwood.magpie.playback

import android.app.PendingIntent
import android.content.Intent
import android.os.Bundle
import android.os.SystemClock
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.session.MediaSession
import androidx.media3.session.MediaSessionService
import androidx.media3.session.SessionCommand
import androidx.media3.session.SessionResult
import androidx.media3.session.SessionError
import com.google.common.util.concurrent.Futures
import com.google.common.util.concurrent.ListenableFuture
import com.henrydashwood.magpie.MainActivity
import com.henrydashwood.magpie.data.ContentKind
import com.henrydashwood.magpie.data.LibraryItem
import com.henrydashwood.magpie.data.PreviewStore
import com.henrydashwood.magpie.data.SampleLibrary
import java.io.File
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

data class Preparation(val itemId: String? = null, val message: String? = null, val error: String? = null, val voice: String? = null)

/** Only status crosses into the UI; the service owns the player and rendering lifecycle. */
object PlaybackStatus {
    internal val mutable = MutableStateFlow(Preparation())
    val state = mutable.asStateFlow()
    internal val mutableSleepTimer = MutableStateFlow(SleepTimerState())
    val sleepTimer = mutableSleepTimer.asStateFlow()
    internal val mutableReadingPosition = MutableStateFlow<ArticleReadingPosition?>(null)
    val readingPosition = mutableReadingPosition.asStateFlow()
}

// Media3 still marks session negotiation and some service controls as unstable.
// All use is contained here and exercised through the real controller in PlaybackTest.
@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
class PlaybackService : MediaSessionService() {
    private lateinit var player: ExoPlayer
    private lateinit var session: MediaSession
    private lateinit var store: PreviewStore
    private lateinit var renderer: ArticleRenderer
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var rendering: Job? = null
    private var current: LibraryItem? = null
    private var rendered: RenderedArticle? = null
    private val library = SampleLibrary()
    private var sleepJob: Job? = null
    private val feedback = PlaybackFeedback(scope)
    private val sleepTimer = SleepTimer(SystemClock::elapsedRealtime,
        changed = { PlaybackStatus.mutableSleepTimer.value = it }, expired = ::expireSleepTimer)

    override fun onCreate() {
        super.onCreate()
        store = PreviewStore(this)
        renderer = ArticleRenderer(this)
        // Private disposable preview audio only; no user downloads are stored here.
        File(cacheDir, "narration").deleteRecursively()
        File(cacheDir, "narration").mkdirs()
        player = ExoPlayer.Builder(this).build().apply {
            setAudioAttributes(AudioAttributes.Builder().setUsage(C.USAGE_MEDIA).setContentType(C.AUDIO_CONTENT_TYPE_SPEECH).build(), true)
            setHandleAudioBecomingNoisy(true)
            setWakeMode(C.WAKE_MODE_LOCAL)
            setPlaybackSpeed(store.speed(ContentKind.Podcast))
            addListener(object : Player.Listener {
                override fun onPlayWhenReadyChanged(playWhenReady: Boolean, reason: Int) {
                    if (playWhenReady) sleepTimer.check()
                }
                override fun onEvents(player: Player, events: Player.Events) { publishReadingPosition() }
                override fun onIsPlayingChanged(isPlaying: Boolean) { persist() }
                override fun onPlaybackParametersChanged(parameters: androidx.media3.common.PlaybackParameters) {
                    current?.let { store.saveSpeed(it.kind, parameters.speed) }
                }
                override fun onPlaybackStateChanged(playbackState: Int) {
                    if (playbackState == Player.STATE_ENDED) finishPlayback()
                }
                override fun onPlayerError(error: PlaybackException) {
                    PlaybackStatus.mutable.value = Preparation(error = "Playback stopped. Open the item and try again.")
                }
            })
        }
        val activity = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        session = MediaSession.Builder(this, player).setSessionActivity(activity).setCallback(object : MediaSession.Callback {
            // Media3's custom-command negotiation builder is still marked unstable.
            @androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
            override fun onConnect(session: MediaSession, controller: MediaSession.ControllerInfo): MediaSession.ConnectionResult {
                val connection = super.onConnect(session, controller)
                val commands = connection.availableSessionCommands.buildUpon()
                if (controller.uid == applicationInfo.uid) {
                    commands.add(SessionCommand(PLAY_ITEM, Bundle.EMPTY))
                    commands.add(SessionCommand(CANCEL_PREPARATION, Bundle.EMPTY))
                    commands.add(SessionCommand(DISMISS_PLAYER, Bundle.EMPTY))
                    commands.add(SessionCommand(SET_SLEEP_TIMER, Bundle.EMPTY))
                    commands.add(SessionCommand(CANCEL_SLEEP_TIMER, Bundle.EMPTY))
                }
                return MediaSession.ConnectionResult.AcceptedResultBuilder(session, controller)
                    .setAvailableSessionCommands(commands.build()).build()
            }

            override fun onCustomCommand(session: MediaSession, controller: MediaSession.ControllerInfo, command: SessionCommand, args: Bundle): ListenableFuture<SessionResult> {
                if (controller.uid != applicationInfo.uid) return Futures.immediateFuture(SessionResult(SessionError.ERROR_PERMISSION_DENIED))
                when (command.customAction) {
                    PLAY_ITEM -> {
                        val item = library.items.find { it.id == args.getString("id") }
                            ?: return Futures.immediateFuture(SessionResult(SessionError.ERROR_BAD_VALUE))
                        play(item)
                    }
                    CANCEL_PREPARATION -> {
                        rendering?.cancel()
                        PlaybackStatus.mutable.value = Preparation()
                    }
                    SET_SLEEP_TIMER -> {
                        if (!sleepTimer.start(args.getLong(SLEEP_DURATION_MS))) {
                            return Futures.immediateFuture(SessionResult(SessionError.ERROR_BAD_VALUE))
                        }
                        sleepJob?.cancel()
                        sleepJob = scope.launch {
                            while (sleepTimer.state.running) {
                                val remaining = checkNotNull(sleepTimer.state.deadlineMs) - SystemClock.elapsedRealtime()
                                delay(remaining.coerceIn(1L, 1_000L))
                                sleepTimer.check()
                            }
                        }
                    }
                    CANCEL_SLEEP_TIMER -> cancelSleepTimer()
                    DISMISS_PLAYER -> dismissPlayer()
                    else -> return Futures.immediateFuture(SessionResult(SessionError.ERROR_NOT_SUPPORTED))
                }
                return Futures.immediateFuture(SessionResult(SessionResult.RESULT_SUCCESS))
            }
        }).build()
        scope.launch {
            while (isActive) { delay(3_000); if (player.isPlaying) persist() }
        }
        scope.launch { while (isActive) { publishReadingPosition(); delay(100) } }
        // A previous session is offered paused. Restoring never unexpectedly starts audio.
        store.lastItem?.let { id -> library.items.find { it.id == id && it.kind == ContentKind.Podcast }?.let { load(it, null, false) } }
    }

    private fun play(item: LibraryItem) {
        feedback.close()
        // Clear an elapsed deadline before a new, explicit request to listen.
        sleepTimer.check()
        if (current?.id == item.id && player.playbackState != Player.STATE_IDLE && PlaybackStatus.state.value.message == null &&
            (item.kind == ContentKind.Podcast || rendered?.voiceSelection == store.voiceId)) {
            if (player.playbackState == Player.STATE_ENDED) player.seekTo(0)
            player.play()
            return
        }
        persist()
        player.pause()
        val previous = rendering
        previous?.cancel()
        PlaybackStatus.mutable.value = Preparation(item.id, if (item.kind == ContentKind.Article) "Starting the reading voice…" else "Opening audio…")
        rendering = scope.launch {
            previous?.join()
            try {
                val audio = if (item.kind == ContentKind.Article) renderer.render(item, store.voiceId) { done, total ->
                    PlaybackStatus.mutable.value = Preparation(item.id, "Preparing audio… ${done * 100 / total}%")
                } else null
                load(item, audio, true)
                PlaybackStatus.mutable.value = Preparation(voice = audio?.voiceName)
            } catch (_: TimeoutCancellationException) {
                PlaybackStatus.mutable.value = Preparation(error = "The reading voice took too long to respond. Please try again.")
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Exception) {
                PlaybackStatus.mutable.value = Preparation(error = error.message ?: "This item could not be prepared. Please try again.")
            }
        }
    }

    private fun load(item: LibraryItem, audio: RenderedArticle?, autoplay: Boolean) {
        persist()
        player.stop()
        rendered?.file?.delete()
        rendered = audio
        current = item
        player.setPlaybackSpeed(store.speed(item.kind))
        store.lastItem = item.id
        val uri = audio?.file?.toURI()?.toString() ?: "asset:///welcome.wav"
        val media = MediaItem.Builder().setMediaId(item.id).setUri(uri).setMediaMetadata(
            MediaMetadata.Builder().setTitle(item.title).setArtist(item.source).setIsPlayable(true).build(),
        ).build()
        val start = if (audio != null) resumeAt(audio.chunks, store.bookmark(item.id), item.contentVersion) else store.position(item.id)
        player.setMediaItem(media, start)
        player.prepare()
        player.playWhenReady = autoplay
    }

    private fun persist(completed: Boolean = false) {
        val item = current ?: return
        if (item.kind == ContentKind.Podcast) store.savePosition(item.id, if (completed) 0 else player.currentPosition.coerceAtLeast(0))
        else rendered?.let { audio ->
            bookmarkAt(audio.chunks, if (completed) 0 else player.currentPosition, item.contentVersion)?.let { store.saveBookmark(item.id, it) }
        }
    }

    private fun finishPlayback() {
        val item = current ?: return
        if (player.currentMediaItem?.mediaId != item.id) return
        store.finished = store.finished + item.id
        // Reset the bookmark before clearing current, so a later explicit Play
        // starts at the beginning. Clearing also prevents callbacks from writing
        // the ended clock over that bookmark or restoring the finished player.
        persist(completed = true)
        dismissPlayer()
        feedback.finished()
    }

    private fun dismissPlayer() {
        // Keep each item's bookmark, but forget what to restore into the mini player.
        persist(completed = player.playbackState == Player.STATE_ENDED)
        rendering?.cancel()
        cancelSleepTimer()
        PlaybackStatus.mutable.value = Preparation()
        current = null
        store.lastItem = null
        player.stop()
        player.clearMediaItems()
        rendered?.file?.delete()
        rendered = null
        PlaybackStatus.mutableReadingPosition.value = null
    }

    private fun publishReadingPosition() {
        val item = current
        val audio = rendered
        val active = item != null && audio != null && item.kind == ContentKind.Article &&
            player.currentMediaItem?.mediaId == item.id && player.playbackState != Player.STATE_IDLE &&
            player.playbackState != Player.STATE_ENDED && PlaybackStatus.state.value.message == null
        val range = if (active) readingRangeAt(audio!!.chunks, audio.ranges, player.currentPosition) else null
        PlaybackStatus.mutableReadingPosition.value = range?.let {
            ArticleReadingPosition(item!!.id, item.contentVersion, it.startUtf16, it.endUtf16)
        }
    }

    private fun cancelSleepTimer() {
        sleepJob?.cancel()
        sleepJob = null
        sleepTimer.cancel()
    }

    private fun expireSleepTimer() {
        val wasPlaying = player.isPlaying
        // Also stop buffering or narration preparation so it cannot start after the deadline.
        rendering?.cancel()
        PlaybackStatus.mutable.value = Preparation()
        player.pause()
        persist()
        if (wasPlaying) feedback.finished()
    }

    override fun onGetSession(controllerInfo: MediaSession.ControllerInfo): MediaSession? =
        if (controllerInfo.uid == applicationInfo.uid || controllerInfo.isTrusted) session else null

    override fun onDestroy() {
        persist(completed = player.playbackState == Player.STATE_ENDED)
        cancelSleepTimer()
        feedback.close()
        scope.cancel()
        renderer.close()
        session.release()
        player.release()
        rendered?.file?.delete()
        PlaybackStatus.mutable.value = Preparation()
        PlaybackStatus.mutableReadingPosition.value = null
        super.onDestroy()
    }

    companion object {
        const val PLAY_ITEM = "magpie.play_sample"
        const val DISMISS_PLAYER = "magpie.dismiss_player"
        const val CANCEL_PREPARATION = "magpie.cancel_preparation"
        const val SET_SLEEP_TIMER = "magpie.set_sleep_timer"
        const val CANCEL_SLEEP_TIMER = "magpie.cancel_sleep_timer"
        const val SLEEP_DURATION_MS = "duration_ms"
    }
}
