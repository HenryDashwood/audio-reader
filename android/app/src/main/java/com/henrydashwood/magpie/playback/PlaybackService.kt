package com.henrydashwood.magpie.playback

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioManager
import androidx.core.content.ContextCompat
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
import com.google.common.util.concurrent.SettableFuture
import com.henrydashwood.magpie.MainActivity
import com.henrydashwood.magpie.MagpieApplication
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import com.henrydashwood.magpie.data.ContentKind
import com.henrydashwood.magpie.data.LibraryItem
import com.henrydashwood.magpie.data.PreviewStore
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
    internal val mutableVoiceToken = MutableStateFlow<String?>(null)
    val voiceToken = mutableVoiceToken.asStateFlow()
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
    private val library by lazy { (application as MagpieApplication).library }
    private var playbackRevision = -1
    private var lastReportedAt = 0L
    private val localPodcastPositions = mutableMapOf<String, Long>()
    private val filedArticleBookmarks = mutableMapOf<String, ArticleBookmark>()
    private val reportLock = Mutex()
    private var sleepJob: Job? = null
    private data class VoiceHold(val token: String, val revision: Int, val item: LibraryItem?, var resume: Boolean)
    private var voiceHold: VoiceHold? = null
    private var voiceController: MediaSession.ControllerInfo? = null
    private val noisyReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action == AudioManager.ACTION_AUDIO_BECOMING_NOISY) invalidateVoice()
        }
    }
    private val feedback = PlaybackFeedback(scope)
    private val sleepTimer = SleepTimer(SystemClock::elapsedRealtime,
        changed = { PlaybackStatus.mutableSleepTimer.value = it }, expired = ::expireSleepTimer)

    override fun onCreate() {
        super.onCreate()
        store = PreviewStore(this)
        renderer = ArticleRenderer(this)
        ContextCompat.registerReceiver(this, noisyReceiver, IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY), ContextCompat.RECEIVER_NOT_EXPORTED)
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
                    commands.add(SessionCommand(BEGIN_VOICE, Bundle.EMPTY))
                    commands.add(SessionCommand(END_VOICE, Bundle.EMPTY))
                    commands.add(SessionCommand(VOICE_CONTROL, Bundle.EMPTY))
                }
                return MediaSession.ConnectionResult.AcceptedResultBuilder(session, controller)
                    .setAvailableSessionCommands(commands.build()).build()
            }

            override fun onPlayerInteractionFinished(session: MediaSession, controllerInfo: MediaSession.ControllerInfo, playerCommands: Player.Commands) {
                // Includes an explicit Pause while already paused, which emits no player event.
                if (listOf(Player.COMMAND_PLAY_PAUSE, Player.COMMAND_STOP, Player.COMMAND_SEEK_IN_CURRENT_MEDIA_ITEM,
                    Player.COMMAND_SEEK_BACK, Player.COMMAND_SEEK_FORWARD, Player.COMMAND_SET_SPEED_AND_PITCH,
                    Player.COMMAND_SET_MEDIA_ITEM, Player.COMMAND_CHANGE_MEDIA_ITEMS).any(playerCommands::contains)) invalidateVoice()
            }

            override fun onDisconnected(session: MediaSession, controller: MediaSession.ControllerInfo) {
                if (controller == voiceController) invalidateVoice()
            }

            override fun onCustomCommand(session: MediaSession, controller: MediaSession.ControllerInfo, command: SessionCommand, args: Bundle): ListenableFuture<SessionResult> {
                if (controller.uid != applicationInfo.uid) return Futures.immediateFuture(SessionResult(SessionError.ERROR_PERMISSION_DENIED))
                if (command.customAction in setOf(BEGIN_VOICE, END_VOICE, VOICE_CONTROL)) {
                    val result = voiceCommand(command.customAction, args)
                    if (command.customAction == BEGIN_VOICE && result.resultCode == SessionResult.RESULT_SUCCESS) voiceController = controller
                    if (result.resultCode == SessionResult.RESULT_SUCCESS && args.getString("action") == "drain") {
                        // Finish older progress writes before the server can file this item.
                        val drained = SettableFuture.create<SessionResult>()
                        scope.launch { reportLock.withLock { drained.set(result) } }
                        return drained
                    }
                    return Futures.immediateFuture(result)
                }
                invalidateVoice()
                when (command.customAction) {
                    PLAY_ITEM -> {
                        val item = library.state.value.items.find { it.id == args.getString("id") }
                            ?: return Futures.immediateFuture(SessionResult(SessionError.ERROR_BAD_VALUE))
                        if (item.episodeId != null && !item.textLoaded) return Futures.immediateFuture(SessionResult(SessionError.ERROR_BAD_VALUE))
                        play(item)
                    }
                    CANCEL_PREPARATION -> {
                        rendering?.cancel()
                        PlaybackStatus.mutable.value = Preparation()
                    }
                    SET_SLEEP_TIMER -> {
                        if (!setSleepTimer(args.getLong(SLEEP_DURATION_MS))) {
                            return Futures.immediateFuture(SessionResult(SessionError.ERROR_BAD_VALUE))
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
            var observed = library.state.value.revision
            library.state.collect { state ->
                if (state.revision != observed) { observed = state.revision; dismissPlayer(); localPodcastPositions.clear(); filedArticleBookmarks.clear() }
                val playing = current
                val updated = state.items.firstOrNull { it.id == playing?.id }
                if (playing?.kind == ContentKind.Article && updated != null && playing.contentId != updated.contentId) {
                    dismissPlayer()
                    store.clearBookmark(playing.id)
                }
            }
        }
        scope.launch {
            while (isActive) { delay(3_000); if (player.isPlaying) persist() }
        }
        scope.launch { while (isActive) { publishReadingPosition(); delay(100) } }
        // A previous session is offered paused. Restoring never unexpectedly starts audio.
        if (!library.state.value.live) store.lastItem?.let { id -> library.state.value.items.find { it.id == id && it.kind == ContentKind.Podcast }?.let { load(it, null, false) } }
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
        playbackRevision = library.state.value.revision
        player.setPlaybackSpeed(store.speed(item.kind))
        store.lastItem = item.id
        val uri = audio?.file?.toURI()?.toString() ?: item.audioUrl ?: "asset:///welcome.wav"
        val media = MediaItem.Builder().setMediaId(item.id).setUri(uri).setMediaMetadata(
            MediaMetadata.Builder().setTitle(item.title).setArtist(item.source).setIsPlayable(true).build(),
        ).build()
        val start = if (audio != null) resumeAt(audio.chunks, store.bookmark(item.id), item.contentVersion) else if (item.episodeId != null) localPodcastPositions[item.id] ?: item.remotePositionMs else store.position(item.id)
        player.setMediaItem(media, start)
        player.prepare()
        player.playWhenReady = autoplay
    }

    private fun persist(completed: Boolean = false) {
        val item = current ?: return
        if (item.kind == ContentKind.Podcast) {
            val position = if (completed) 0 else player.currentPosition.coerceAtLeast(0)
            store.savePosition(item.id, position)
            if (item.episodeId != null) localPodcastPositions[item.id] = position
        }
        else rendered?.let { audio ->
            bookmarkAt(audio.chunks, if (completed) 0 else player.currentPosition, item.contentVersion)?.let { store.saveBookmark(item.id, it) }
        }
        if (voiceHold == null && item.episodeId != null && item.kind == ContentKind.Podcast && playbackRevision == library.state.value.revision &&
            (completed || !player.isPlaying || SystemClock.elapsedRealtime() - lastReportedAt >= 30_000)) {
            lastReportedAt = SystemClock.elapsedRealtime()
            val version = playbackRevision
            val seconds = player.currentPosition.coerceAtLeast(0) / 1000.0
            scope.launch { reportLock.withLock {
                if (version == library.state.value.revision) try { library.reportPodcast(item, seconds, completed) }
                catch (cancelled: CancellationException) { throw cancelled }
                catch (_: Exception) { if (version == library.state.value.revision) PlaybackStatus.mutable.value = PlaybackStatus.state.value.copy(error = "Listening progress could not be synced. Your place is saved on this device.") }
            } }
        }
    }

    private fun finishPlayback() {
        val item = current ?: return
        if (player.currentMediaItem?.mediaId != item.id) return
        if (item.episodeId == null) store.finished = store.finished + item.id
        else {
            val version = playbackRevision
            scope.launch {
                if (version == library.state.value.revision) try { library.played(item, true) }
                catch (cancelled: CancellationException) { throw cancelled }
                catch (_: Exception) { if (version == library.state.value.revision) PlaybackStatus.mutable.value = Preparation(error = "Finished status could not be synced. Please mark the item as read again when connected.") }
            }
        }
        // Reset the bookmark before clearing current, so a later explicit Play
        // starts at the beginning. Clearing also prevents callbacks from writing
        // the ended clock over that bookmark or restoring the finished player.
        persist(completed = true)
        dismissPlayer()
        feedback.finished()
    }

    private fun dismissPlayer() {
        invalidateVoice()
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

    private fun invalidateVoice() {
        voiceHold = null
        voiceController = null
        PlaybackStatus.mutableVoiceToken.value = null
    }

    private fun voiceCommand(action: String, args: Bundle): SessionResult {
        val token = args.getString("token") ?: return SessionResult(SessionError.ERROR_BAD_VALUE)
        if (action == BEGIN_VOICE) {
            if (!token.matches(Regex("[a-zA-Z0-9-]{1,64}")) || args.getInt("revision", -1) != library.state.value.revision)
                return SessionResult(SessionError.ERROR_BAD_VALUE)
            sleepTimer.check()
            val preparing = PlaybackStatus.state.value.takeIf { it.message != null }?.itemId
                ?.let { id -> library.state.value.items.find { it.id == id } }
            voiceHold = VoiceHold(token, library.state.value.revision, preparing ?: current,
                preparing != null || player.playWhenReady)
            PlaybackStatus.mutableVoiceToken.value = token
            rendering?.cancel()
            PlaybackStatus.mutable.value = Preparation()
            player.pause()
            feedback.close()
            return SessionResult(SessionResult.RESULT_SUCCESS)
        }
        val hold = voiceHold?.takeIf { it.token == token && it.revision == library.state.value.revision }
            ?: return SessionResult(SessionError.ERROR_INVALID_STATE)
        if (action == END_VOICE) {
            invalidateVoice()
            val item = hold.item?.let { old -> library.state.value.items.find { it.id == old.id && it.contentVersion == old.contentVersion } }
            if (args.getBoolean("resume", true) && hold.resume && item != null) play(item)
            return SessionResult(SessionResult.RESULT_SUCCESS)
        }
        val result = Bundle()
        when (args.getString("action")) {
            "drain" -> Unit
            "pause" -> { hold.resume = false; player.pause() }
            "resume", "play" -> {
                val id = args.getString("id") ?: hold.item?.id ?: current?.id
                val item = library.state.value.items.find { it.id == id && it.textLoaded }
                    ?: return SessionResult(SessionError.ERROR_BAD_VALUE)
                hold.resume = false
                play(item)
            }
            "seek" -> {
                if (current == null || player.duration <= 0) return SessionResult(SessionError.ERROR_INVALID_STATE)
                val delta = args.getLong("delta_ms").coerceIn(-7_200_000, 7_200_000)
                player.seekTo((player.currentPosition + delta).coerceIn(0, player.duration))
            }
            "speed" -> {
                val kind = ContentKind.entries.firstOrNull { it.name == args.getString("kind") }
                    ?: current?.kind ?: ContentKind.Podcast
                val rate = args.getFloat("rate")
                if (!rate.isFinite() || rate !in .5f..3f) return SessionResult(SessionError.ERROR_BAD_VALUE)
                result.putFloat("previous_rate", store.speed(kind)); result.putString("kind", kind.name)
                store.saveSpeed(kind, rate)
                if (current?.kind == kind) player.setPlaybackSpeed(rate)
            }
            "sleep" -> if (!setSleepTimer(args.getLong(SLEEP_DURATION_MS))) return SessionResult(SessionError.ERROR_BAD_VALUE)
            "cancel_sleep" -> cancelSleepTimer()
            "restore" -> {
                val item = library.state.value.items.find { it.id == args.getString("id") }
                if (item?.kind == ContentKind.Podcast) {
                    val position = args.getLong("position_ms").coerceAtLeast(0)
                    localPodcastPositions[item.id] = position; store.savePosition(item.id, position)
                    if (current?.id == item.id) player.seekTo(position)
                } else if (item != null) {
                    filedArticleBookmarks.remove(item.id)?.takeIf { it.contentVersion == item.contentVersion }
                        ?.let { store.saveBookmark(item.id, it) }
                }
            }
            "file" -> {
                val id = args.getString("id")
                val item = library.state.value.items.find { it.id == id }
                if (item?.kind == ContentKind.Article) {
                    // Keep the bookmark for Undo even when a receipt is replayed after cancellation.
                    store.bookmark(item.id)?.let { filedArticleBookmarks[item.id] = it }
                }
                if (item?.completed == true) {
                    store.clearBookmark(item.id); store.savePosition(item.id, 0)
                    localPodcastPositions[item.id] = 0
                }
                if (current?.id == id || hold.item?.id == id) {
                    hold.resume = false
                    // The server already filed it. Never report the old clock as unplayed.
                    rendering?.cancel(); current = null; store.lastItem = null
                    player.stop(); player.clearMediaItems()
                    rendered?.file?.delete(); rendered = null
                    PlaybackStatus.mutable.value = Preparation()
                    cancelSleepTimer()
                }
            }
            else -> return SessionResult(SessionError.ERROR_NOT_SUPPORTED)
        }
        return SessionResult(SessionResult.RESULT_SUCCESS, result)
    }

    private fun setSleepTimer(duration: Long): Boolean {
        if (!sleepTimer.start(duration)) return false
        sleepJob?.cancel()
        sleepJob = scope.launch {
            while (sleepTimer.state.running) {
                val remaining = checkNotNull(sleepTimer.state.deadlineMs) - SystemClock.elapsedRealtime()
                delay(remaining.coerceIn(1L, 1_000L))
                sleepTimer.check()
            }
        }
        return true
    }

    private fun cancelSleepTimer() {
        sleepJob?.cancel()
        sleepJob = null
        sleepTimer.cancel()
    }

    private fun expireSleepTimer() {
        invalidateVoice()
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
        unregisterReceiver(noisyReceiver)
        invalidateVoice()
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
        const val BEGIN_VOICE = "magpie.begin_voice"
        const val END_VOICE = "magpie.end_voice"
        const val VOICE_CONTROL = "magpie.voice_control"
        const val PLAY_ITEM = "magpie.play_sample"
        const val DISMISS_PLAYER = "magpie.dismiss_player"
        const val CANCEL_PREPARATION = "magpie.cancel_preparation"
        const val SET_SLEEP_TIMER = "magpie.set_sleep_timer"
        const val CANCEL_SLEEP_TIMER = "magpie.cancel_sleep_timer"
        const val SLEEP_DURATION_MS = "duration_ms"
    }
}
