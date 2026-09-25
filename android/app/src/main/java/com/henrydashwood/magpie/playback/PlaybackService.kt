package com.henrydashwood.magpie.playback

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioManager
import androidx.core.content.ContextCompat
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.ForwardingPlayer
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.session.MediaSession
import androidx.media3.session.MediaLibraryService
import androidx.media3.session.LibraryResult
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
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

data class Preparation(val itemId: String? = null, val message: String? = null, val error: String? = null, val voice: String? = null)

/** Only status crosses into the UI; the service owns the player and rendering lifecycle. */
object PlaybackStatus {
    internal val mutableControlVersion = MutableStateFlow(0)
    val controlVersion = mutableControlVersion.asStateFlow()
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
class PlaybackService : MediaLibraryService() {
    private lateinit var player: ExoPlayer
    private lateinit var session: MediaLibrarySession
    private lateinit var store: PreviewStore
    private lateinit var renderer: ArticleRenderer
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var rendering: Job? = null
    private var current: LibraryItem? = null
    private var currentOwner: String? = null
    private var restoreAllowed = false
    private var restoreAttempt: Pair<Int, String?>? = null
    private var restoring: Job? = null
    private var pendingRestoration: Pair<String?, String>? = null
    private var rendered: RenderedArticle? = null
    private val library by lazy { (application as MagpieApplication).library }
    private val catalog by lazy { MediaLibraryCatalog(library, store) }
    private val browserJobs = mutableMapOf<MediaSession.ControllerInfo, MutableSet<Job>>()
    private var assistantJob: Job? = null
    private var assistantFuture: SettableFuture<MediaSession.MediaItemsWithStartPosition>? = null
    private var assistantController: MediaSession.ControllerInfo? = null
    private var resumptionInteraction: MediaSession.ControllerInfo? = null
    private val cancelledPlayback = mutableMapOf<MediaSession.ControllerInfo, Any>()
    private val mainHandler = Handler(Looper.getMainLooper())
    private class AutomationPlayback(val controller: MediaSession.ControllerInfo, val revision: Int, val controls: Int) {
        val result = SettableFuture.create<SessionResult>()
        lateinit var job: Job
        var applied = false
        var foregroundDenied = false
    }
    private var automationPlayback: AutomationPlayback? = null
    private var automationSpeedUndo: com.henrydashwood.magpie.data.AccountLibrary.SpeedUndo?
        get() = library.speedUndo
        set(value) { library.speedUndo = value }
    private var playbackRevision = -1
    private var lastReportedAt = 0L
    private var progressPlaybackId: String? = null
    private var hasPlayed = false
    private val localPodcastPositions = mutableMapOf<String, Long>()
    private val filedArticleBookmarks = mutableMapOf<String, ArticleBookmark>()
    private val reportLock = Mutex()
    private var sleepJob: Job? = null
    private data class VoiceHold(val token: String, val revision: Int, val item: LibraryItem?, var resume: Boolean,
        val requests: MutableSet<String> = mutableSetOf())
    // A lost receipt may already have filed the item on the server. Keep its old
    // clock off the wire even after independent controls invalidate the voice hold.
    private val uncertainProgress = mutableMapOf<String, MutableSet<String>>()
    private var voiceHold: VoiceHold? = null
    private var voiceController: MediaSession.ControllerInfo? = null
    private val noisyReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action == AudioManager.ACTION_AUDIO_BECOMING_NOISY) {
                PlaybackStatus.mutableControlVersion.value++
                cancelAssistant()
                invalidateVoice()
            }
        }
    }
    private val feedback = PlaybackFeedback(this, scope)
    private val sleepTimer = SleepTimer(SystemClock::elapsedRealtime,
        changed = { PlaybackStatus.mutableSleepTimer.value = it }, expired = ::expireSleepTimer)

    override fun onCreate() {
        super.onCreate()
        setListener(object : androidx.media3.session.MediaSessionService.Listener {
            override fun onForegroundServiceStartNotAllowedException() {
                automationPlayback?.let { it.foregroundDenied = true; player.pause() }
            }
        })
        store = PreviewStore(this)
        renderer = ArticleRenderer(this)
        ContextCompat.registerReceiver(this, noisyReceiver, IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY), ContextCompat.RECEIVER_NOT_EXPORTED)
        // Private disposable preview audio only; no user downloads are stored here.
        File(cacheDir, "narration").deleteRecursively()
        File(cacheDir, "narration").mkdirs()
        player = ExoPlayer.Builder(this).setMediaSourceFactory(ArticleMediaSourceFactory(this, renderer)).build().apply {
            setAudioAttributes(AudioAttributes.Builder().setUsage(C.USAGE_MEDIA).setContentType(C.AUDIO_CONTENT_TYPE_SPEECH).build(), true)
            setHandleAudioBecomingNoisy(true)
            setWakeMode(C.WAKE_MODE_LOCAL)
            setPlaybackSpeed(store.speed(ContentKind.Podcast))
            addListener(object : Player.Listener {
                override fun onPlayWhenReadyChanged(playWhenReady: Boolean, reason: Int) {
                    if (playWhenReady) sleepTimer.check()
                }
                override fun onEvents(player: Player, events: Player.Events) { publishReadingPosition() }
                override fun onIsPlayingChanged(isPlaying: Boolean) {
                    if (isPlaying) hasPlayed = true
                    persist()
                }
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
        val sessionPlayer = object : ForwardingPlayer(player) {
            private fun mayPlay() = cancelledPlayback.isEmpty() ||
                session.controllerForCurrentRequest?.let { it !in cancelledPlayback } == true
            override fun play() { if (mayPlay()) { beginProgressIntent(); super.play() } }
            override fun pause() { cancelAssistant(); resumptionInteraction = null; super.pause() }
            override fun stop() { cancelAssistant(); resumptionInteraction = null; super.stop() }
            override fun setPlayWhenReady(playWhenReady: Boolean) {
                if (!playWhenReady) { cancelAssistant(); resumptionInteraction = null }
                if (!playWhenReady || mayPlay()) {
                    if (playWhenReady) beginProgressIntent()
                    super.setPlayWhenReady(playWhenReady)
                }
            }
        }
        session = MediaLibrarySession.Builder(this, sessionPlayer, object : MediaLibrarySession.Callback {
            // Media3's custom-command negotiation builder is still marked unstable.
            @androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
            override fun onConnect(session: MediaSession, controller: MediaSession.ControllerInfo): MediaSession.ConnectionResult {
                if (!trusted(controller)) return MediaSession.ConnectionResult.reject()
                val commands = MediaSession.ConnectionResult.DEFAULT_SESSION_AND_LIBRARY_COMMANDS.buildUpon()
                if (controller.uid == applicationInfo.uid) {
                    commands.add(SessionCommand(AUTOMATION_CONTROL, Bundle.EMPTY))
                    commands.add(SessionCommand(PLAY_ITEM, Bundle.EMPTY))
                    commands.add(SessionCommand(RESTORE_PLAYER, Bundle.EMPTY))
                    commands.add(SessionCommand(CANCEL_PREPARATION, Bundle.EMPTY))
                    commands.add(SessionCommand(DISMISS_PLAYER, Bundle.EMPTY))
                    commands.add(SessionCommand(SET_SLEEP_TIMER, Bundle.EMPTY))
                    commands.add(SessionCommand(CANCEL_SLEEP_TIMER, Bundle.EMPTY))
                    commands.add(SessionCommand(BEGIN_VOICE, Bundle.EMPTY))
                    commands.add(SessionCommand(END_VOICE, Bundle.EMPTY))
                    commands.add(SessionCommand(VOICE_CONTROL, Bundle.EMPTY))
                }
                return MediaSession.ConnectionResult.AcceptedResultBuilder(session, controller)
                    .setAvailableSessionCommands(commands.build())
                    // Magpie owns a single item; arbitrary queues/URIs cannot enter its player.
                    .setAvailablePlayerCommands(MediaSession.ConnectionResult.DEFAULT_PLAYER_COMMANDS.buildUpon()
                        .remove(Player.COMMAND_CHANGE_MEDIA_ITEMS).build()).build()
            }

            override fun onPlayerInteractionFinished(session: MediaSession, controllerInfo: MediaSession.ControllerInfo, playerCommands: Player.Commands) {
                // Media3 finishes the originating Play interaction before asynchronous
                // resumption preparation completes. It must not cancel its own request.
                // A subsequent Pause/Stop cancels immediately in the forwarding player.
                if (controllerInfo == resumptionInteraction && playerCommands.contains(Player.COMMAND_PLAY_PAUSE)) {
                    resumptionInteraction = null
                    if (playerCommands.size() == 1) return
                }
                // Includes an explicit Pause while already paused, which emits no player event.
                if (listOf(Player.COMMAND_PLAY_PAUSE, Player.COMMAND_STOP, Player.COMMAND_SEEK_IN_CURRENT_MEDIA_ITEM,
                    Player.COMMAND_SEEK_BACK, Player.COMMAND_SEEK_FORWARD, Player.COMMAND_SET_SPEED_AND_PITCH,
                    Player.COMMAND_SET_MEDIA_ITEM, Player.COMMAND_CHANGE_MEDIA_ITEMS).any(playerCommands::contains)) {
                    PlaybackStatus.mutableControlVersion.value++
                    cancelAssistant(preservePlayback = player.playWhenReady &&
                        (playerCommands.contains(Player.COMMAND_PLAY_PAUSE) || playerCommands.contains(Player.COMMAND_SET_MEDIA_ITEM)))
                    invalidateVoice()
                }
            }

            override fun onDisconnected(session: MediaSession, controller: MediaSession.ControllerInfo) {
                if (controller == voiceController) invalidateVoice()
                browserJobs.remove(controller)?.toList()?.forEach { it.cancel() }
                if (controller == assistantController || controller == automationPlayback?.controller) cancelAssistant()
            }

            override fun onGetLibraryRoot(session: MediaLibrarySession, browser: MediaSession.ControllerInfo, params: LibraryParams?) =
                Futures.immediateFuture(LibraryResult.ofItem(catalog.root(), params))

            override fun onGetItem(session: MediaLibrarySession, browser: MediaSession.ControllerInfo, mediaId: String) =
                libraryResult(browser) { LibraryResult.ofItem(catalog.item(mediaId), null) }

            override fun onGetChildren(session: MediaLibrarySession, browser: MediaSession.ControllerInfo,
                parentId: String, page: Int, pageSize: Int, params: LibraryParams?) = libraryResult(browser) {
                LibraryResult.ofItemList(catalog.children(parentId, page, pageSize), params)
            }

            override fun onSearch(session: MediaLibrarySession, browser: MediaSession.ControllerInfo, query: String, params: LibraryParams?) =
                libraryResult(browser) {
                    val results = catalog.search(query)
                    session.notifySearchResultChanged(browser, query, results.size, params)
                    LibraryResult.ofVoid(params)
                }

            override fun onGetSearchResult(session: MediaLibrarySession, browser: MediaSession.ControllerInfo,
                query: String, page: Int, pageSize: Int, params: LibraryParams?) = libraryResult(browser) {
                MediaLibraryCatalog.validatePage(page, pageSize)
                LibraryResult.ofItemList(MediaLibraryCatalog.paginate(catalog.search(query), page, pageSize).map(MediaLibraryCatalog::media), params)
            }

            override fun onSetMediaItems(session: MediaSession, controller: MediaSession.ControllerInfo,
                mediaItems: MutableList<MediaItem>, startIndex: Int, startPositionMs: Long): ListenableFuture<MediaSession.MediaItemsWithStartPosition> =
                prepareAssistant(controller, mediaItems, startIndex, startPositionMs)

            override fun onPlaybackResumption(session: MediaSession, controller: MediaSession.ControllerInfo,
                isForPlayback: Boolean): ListenableFuture<MediaSession.MediaItemsWithStartPosition> =
                resumePlayback(controller, isForPlayback)

            override fun onAddMediaItems(session: MediaSession, controller: MediaSession.ControllerInfo,
                mediaItems: MutableList<MediaItem>): ListenableFuture<MutableList<MediaItem>> =
                Futures.immediateFailedFuture(UnsupportedOperationException("Choose one Magpie item to play."))

            override fun onCustomCommand(session: MediaSession, controller: MediaSession.ControllerInfo, command: SessionCommand, args: Bundle): ListenableFuture<SessionResult> {
                if (controller.uid != applicationInfo.uid) return Futures.immediateFuture(SessionResult(SessionError.ERROR_PERMISSION_DENIED))
                if (command.customAction == AUTOMATION_CONTROL) return automationCommand(controller, args)
                if (command.customAction in setOf(BEGIN_VOICE, END_VOICE, VOICE_CONTROL)) {
                    val result = voiceCommand(command.customAction, args)
                    if (command.customAction == BEGIN_VOICE && result.resultCode == SessionResult.RESULT_SUCCESS) voiceController = controller
                    val progressAction = args.getString("action")
                    if (result.resultCode == SessionResult.RESULT_SUCCESS &&
                        progressAction in setOf("drain", "confirm", "file", "restore")) {
                        val finished = SettableFuture.create<SessionResult>()
                        val version = library.state.value.revision
                        val request = args.getString("request_id") ?: args.getString("token")!!
                        val ids = if (progressAction == "drain") library.state.value.items
                            .filter { request in uncertainProgress[it.id].orEmpty() }.mapNotNull { it.episodeId }.toSet()
                        else library.state.value.items.filter { it.id == args.getString("id") }.mapNotNull { it.episodeId }.toSet()
                        (application as MagpieApplication).progressWork {
                            try {
                                check(version == library.state.value.revision)
                                when (progressAction) {
                                    "drain" -> {
                                        // Save the guard before allowing the server mutation, then
                                        // wait for earlier app-owned and legacy service writes.
                                        library.holdProgress(ids, request)
                                        reportLock.withLock { library.awaitProgress() }
                                    }
                                    "confirm" -> library.confirmProgress(request)
                                    else -> library.blockProgress(ids)
                                }
                                check(version == library.state.value.revision)
                                finished.set(result)
                            } catch (failure: Exception) { finished.setException(failure) }
                        }
                        return finished
                    }
                    return Futures.immediateFuture(result)
                }
                if (command.customAction == RESTORE_PLAYER) {
                    restoreAllowed = true; restoreIfReady()
                    return Futures.immediateFuture(SessionResult(SessionResult.RESULT_SUCCESS))
                }
                PlaybackStatus.mutableControlVersion.value++
                cancelAssistant()
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
        }).setSessionActivity(activity).build()
        scope.launch {
            var observed = library.state.value.revision
            var previousFolders = emptySet<String>()
            library.state.collect { state ->
                if (state.revision != observed) { restoreAllowed = false; observed = state.revision; automationSpeedUndo = null; uncertainProgress.clear(); dismissPlayer(); localPodcastPositions.clear(); filedArticleBookmarks.clear() }
                session.notifyChildrenChanged(MediaLibraryCatalog.ROOT, 3, null)
                val folders = catalog.containerIds(state)
                // Like Media3's default subscription, unknown fresh counts prompt a reload.
                // Removed/account-scoped folders are explicitly emptied.
                (previousFolders + folders).forEach { session.notifyChildrenChanged(it, if (it in folders) Int.MAX_VALUE else 0, null) }
                previousFolders = folders
                val playing = current
                val updated = state.items.firstOrNull { it.id == playing?.id }
                if (playing?.kind == ContentKind.Article && updated != null && playing.contentId != updated.contentId) {
                    dismissPlayer()
                    store.clearBookmark(playing.id)
                }
                restoreIfReady()
            }
        }
        scope.launch {
            while (isActive) { delay(3_000); if (player.isPlaying) persist() }
        }
        scope.launch { while (isActive) { publishReadingPosition(); delay(100) } }
        // A previous session is offered paused. Restoring never unexpectedly starts audio.
        // The app requests paused restoration after connecting. System metadata
        // queries must not prepare audio or open the speech engine.
    }

    private fun cancelRestoration(forget: Boolean = false) {
        restoring?.cancel(); restoring = null
        if (forget) pendingRestoration?.let { (owner, id) ->
            if (store.restoration(owner) == id) store.saveRestoration(owner, null)
        }
        pendingRestoration = null
    }

    private fun canRestore(item: LibraryItem) = !item.completed && item.captureError == null &&
        (item.episodeId != null || item.id !in store.finished)

    /** Recreate the paused player, without synthesizing an article just to show its title. */
    private fun restoreIfReady() {
        val state = library.state.value
        if (!restoreAllowed || state.loading || state.live && state.owner == null || current != null ||
            rendering?.isActive == true || assistantFuture != null || automationPlayback != null || voiceHold != null) return
        val key = state.revision to state.owner
        if (restoreAttempt == key) return
        restoreAttempt = key
        val id = store.restoration(state.owner) ?: return
        val controls = PlaybackStatus.controlVersion.value
        pendingRestoration = state.owner to id
        restoring = scope.launch {
            try {
                val item = withTimeout(30_000) { library.shortcutItem(id) }
                currentCoroutineContext().ensureActive()
                if (library.state.value.revision != state.revision || library.state.value.owner != state.owner ||
                    PlaybackStatus.controlVersion.value != controls || current != null || store.restoration(state.owner) != id) return@launch
                if (!canRestore(item)) {
                    store.saveRestoration(state.owner, null)
                    if (store.lastItem == id) store.lastItem = null
                    return@launch
                }
                if (item.kind == ContentKind.Podcast) load(item, null, false)
                else {
                    current = item; currentOwner = state.owner; playbackRevision = state.revision
                    hasPlayed = false; progressPlaybackId = null; store.lastItem = item.id
                    // Empty Media3 playback is intentional: Play invokes resumption,
                    // which resolves current text and only then starts the offline voice.
                }
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (_: Exception) { /* A failed passive restore leaves the library usable. */ }
            finally { if (pendingRestoration == (state.owner to id)) pendingRestoration = null }
        }
    }

    private fun resumePlayback(controller: MediaSession.ControllerInfo, forPlayback: Boolean): ListenableFuture<MediaSession.MediaItemsWithStartPosition> {
        val future = SettableFuture.create<MediaSession.MediaItemsWithStartPosition>()
        if (forPlayback) resumptionInteraction = controller
        val initial = library.state.value
        val controls = PlaybackStatus.controlVersion.value
        var prepared: ListenableFuture<MediaSession.MediaItemsWithStartPosition>? = null
        val job = scope.launch(start = CoroutineStart.LAZY) {
            try {
                // System UI metadata inspection is cache-only and must not wait for a refresh.
                val ready = if (forPlayback) withTimeout(30_000) {
                    library.state.first { !it.loading && (!it.live || it.owner != null) }
                } else library.state.value
                check(!ready.live || ready.owner != null) { "Open Magpie to restore your account." }
                if (initial.live != ready.live || initial.owner != null &&
                    (initial.owner != ready.owner || initial.revision != ready.revision) ||
                    controls != PlaybackStatus.controlVersion.value) throw CancellationException("Listening changed")
                val id = store.restoration(ready.owner) ?: throw IllegalStateException("There is no listening item to resume.")
                if (!forPlayback) {
                    // Boot/System UI inspection must not fetch article text or prepare audio.
                    val item = ready.items.firstOrNull { it.id == id && canRestore(it) }
                        ?: throw IllegalStateException("Open Magpie to refresh your listening item.")
                    future.set(MediaSession.MediaItemsWithStartPosition(listOf(MediaLibraryCatalog.media(item)), 0,
                        if (item.kind == ContentKind.Podcast) item.remotePositionMs else 0))
                } else {
                    val request = MediaItem.Builder().setMediaId(id).build()
                    val result = prepareAssistant(controller, listOf(request), 0, C.TIME_UNSET) {
                        val item = library.shortcutItem(id)
                        check(canRestore(item) && store.restoration(ready.owner) == id) { "That listening item is no longer available." }
                        item
                    }
                    prepared = result
                    future.setFuture(result)
                }
            } catch (_: CancellationException) { future.cancel(false) }
            catch (failure: Exception) { future.setException(failure) }
            finally { browserJobs[controller]?.remove(coroutineContext[Job]) }
        }
        browserJobs.getOrPut(controller) { mutableSetOf() }.add(job)
        future.addListener({ if (future.isCancelled) { job.cancel(); prepared?.cancel(false) } }, mainExecutor)
        job.start()
        return future
    }

    private fun <T : Any> libraryResult(controller: MediaSession.ControllerInfo,
        work: suspend () -> LibraryResult<T>): ListenableFuture<LibraryResult<T>> {
        val future = SettableFuture.create<LibraryResult<T>>()
        val revision = library.state.value.revision
        lateinit var job: Job
        job = scope.launch(start = CoroutineStart.LAZY) {
            try {
                val result = withTimeout(30_000) { work() }
                if (library.state.value.revision != revision) throw CancellationException("Account changed")
                future.set(result)
            } catch (_: TimeoutCancellationException) {
                future.set(LibraryResult.ofError<T>(SessionError(SessionError.ERROR_IO, "Magpie took too long to load this library. Try again.", Bundle.EMPTY)))
            } catch (_: CancellationException) {
                future.cancel(false)
            } catch (failure: Exception) {
                val code = if (failure is IllegalArgumentException) SessionError.ERROR_BAD_VALUE else SessionError.ERROR_IO
                future.set(LibraryResult.ofError<T>(SessionError(code, com.henrydashwood.magpie.data.AccountLibrary.message(failure), Bundle.EMPTY)))
            } finally {
                browserJobs[controller]?.let { jobs -> jobs.remove(job); if (jobs.isEmpty()) browserJobs.remove(controller) }
            }
        }
        browserJobs.getOrPut(controller) { mutableSetOf() }.add(job)
        future.addListener({ if (future.isCancelled) job.cancel() }, mainExecutor)
        job.start()
        return future
    }

    private fun cancelAssistant(preservePlayback: Boolean = false) {
        cancelAutomation(preservePlayback)
        val future = assistantFuture ?: return
        val job = assistantJob
        val controller = checkNotNull(assistantController)
        // Clear ownership before completing the future: Media3 may drain its queue inline.
        releaseAssistant(future)
        PlaybackStatus.mutable.value = Preparation()
        withoutQueuedPlay(controller) { job?.cancel(); future.cancel(false) }
    }

    private fun releaseAssistant(future: SettableFuture<MediaSession.MediaItemsWithStartPosition>) {
        if (assistantFuture === future) { assistantJob = null; assistantFuture = null; assistantController = null }
    }

    private fun <T> withoutQueuedPlay(controller: MediaSession.ControllerInfo, complete: () -> T): T {
        // A failed/cancelled SetMediaItem does not remove that caller's queued Play.
        // Suppress playback while Media3 drains those commands, preserving the old
        // item/bookmark. A disconnected caller is reported as null by Media3.
        val marker = Any()
        cancelledPlayback[controller] = marker
        return try { complete() } finally {
            mainHandler.post { if (cancelledPlayback[controller] === marker) cancelledPlayback.remove(controller) }
        }
    }

    /** Resolve first, then let Media3 perform the caller's Prepare or Play command. */
    private fun prepareAssistant(controller: MediaSession.ControllerInfo, requests: List<MediaItem>,
        startIndex: Int, startPositionMs: Long, resolve: (suspend () -> LibraryItem)? = null): ListenableFuture<MediaSession.MediaItemsWithStartPosition> {
        if (requests.size != 1 || startIndex !in listOf(0, C.INDEX_UNSET) ||
            (startPositionMs != C.TIME_UNSET && startPositionMs !in 0..86_400_000))
            return withoutQueuedPlay(controller) {
                Futures.immediateFailedFuture(IllegalArgumentException("Choose one Magpie item and a valid listening position."))
            }
        cancelRestoration()
        PlaybackStatus.mutableControlVersion.value++
        val previousAssistant = assistantJob
        cancelAssistant()
        val previousRendering = rendering
        previousRendering?.cancel()
        invalidateVoice(); feedback.close(); sleepTimer.check()
        persist(); player.pause()
        val future = SettableFuture.create<MediaSession.MediaItemsWithStartPosition>()
        assistantFuture = future; assistantController = controller
        val revision = library.state.value.revision
        val controls = PlaybackStatus.controlVersion.value
        PlaybackStatus.mutable.value = Preparation(message = "Finding your listening item…")
        val job = scope.launch(start = CoroutineStart.LAZY) {
            var audio: RenderedArticle? = null
            var adopted = false
            fun checkRequest() {
                if (assistantFuture !== future || future.isCancelled || library.state.value.revision != revision ||
                    PlaybackStatus.controlVersion.value != controls) throw CancellationException("Listening request changed")
            }
            try {
                withTimeout(120_000) {
                    previousAssistant?.join(); previousRendering?.join()
                    val item = withTimeout(30_000) {
                        val selected = resolve?.invoke() ?: catalog.resolve(requests.single())
                        if (selected.episodeId != null && selected.kind == ContentKind.Article) library.content(selected.id, forPlayback = true) else selected
                    }
                    checkRequest()
                    val reuse = current?.id == item.id && current?.contentVersion == item.contentVersion &&
                        player.currentMediaItem?.mediaId == item.id &&
                        (item.kind == ContentKind.Podcast || rendered?.let { it.voiceSelection == store.voiceId && !it.closed } == true)
                    val position = if (reuse && (item.kind == ContentKind.Podcast || item.episodeId == null ||
                        current?.articleProgress?.revision == item.articleProgress?.revision)) player.currentPosition.coerceAtLeast(0) else null
                    audio = if (reuse) rendered else if (item.kind == ContentKind.Article) renderer.render(item, store.voiceId, articleResumeOffset(item)) { done, total ->
                        checkRequest()
                        PlaybackStatus.mutable.value = Preparation(item.id, "Preparing audio… ${done * 100 / total}%")
                    } else null
                    currentCoroutineContext().ensureActive(); checkRequest()
                    val start = if (startPositionMs != C.TIME_UNSET) startPositionMs else if (item.completed) 0 else position ?: resumePosition(item, audio)
                    val media = adopt(item, audio)
                    adopted = true
                    PlaybackStatus.mutable.value = Preparation(voice = audio?.voiceName)
                    // Completing this on the application thread lets Media3 apply it atomically.
                    releaseAssistant(future)
                    future.set(MediaSession.MediaItemsWithStartPosition(listOf(media), 0, start))
                }
            } catch (_: TimeoutCancellationException) {
                if (assistantFuture === future) PlaybackStatus.mutable.value = Preparation(error = "That item took too long to prepare. Open Magpie and try again.")
                releaseAssistant(future)
                if (!future.isDone) withoutQueuedPlay(controller) { future.setException(IllegalStateException("Listening preparation timed out")) }
            } catch (_: CancellationException) {
                if (assistantFuture === future) PlaybackStatus.mutable.value = Preparation()
                releaseAssistant(future)
                if (!future.isDone) withoutQueuedPlay(controller) { future.cancel(false) }
            } catch (failure: Exception) {
                if (assistantFuture === future) PlaybackStatus.mutable.value = Preparation(error = com.henrydashwood.magpie.data.AccountLibrary.message(failure))
                releaseAssistant(future)
                if (!future.isDone) withoutQueuedPlay(controller) { future.setException(failure) }
            } finally {
                if (!adopted && audio !== rendered) audio?.close()
                releaseAssistant(future)
            }
        }
        assistantJob = job
        future.addListener({ if (future.isCancelled) job.cancel() }, mainExecutor)
        job.start()
        return future
    }

    private fun play(item: LibraryItem, newIntent: Boolean = true) {
        cancelRestoration()
        cancelAssistant()
        feedback.close()
        // Clear an elapsed deadline before a new, explicit request to listen.
        sleepTimer.check()
        if ((!newIntent || item.kind == ContentKind.Podcast || item.episodeId == null) &&
            current?.id == item.id && current?.contentVersion == item.contentVersion && player.playbackState != Player.STATE_IDLE && PlaybackStatus.state.value.message == null &&
            (item.kind == ContentKind.Podcast || rendered?.voiceSelection == store.voiceId)) {
            if (player.playbackState == Player.STATE_ENDED) player.seekTo(0)
            if (newIntent) beginProgressIntent(item)
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
                val resolved = if (newIntent && item.episodeId != null && item.kind == ContentKind.Article)
                    library.content(item.id, forPlayback = true) else item
                val audio = if (resolved.kind == ContentKind.Article) renderer.render(resolved, store.voiceId, articleResumeOffset(resolved)) { done, total ->
                    PlaybackStatus.mutable.value = Preparation(resolved.id, "Preparing audio… ${done * 100 / total}%")
                } else null
                load(resolved, audio, true)
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
        val start = resumePosition(item, audio)
        val media = adopt(item, audio)
        player.setMediaItem(media, start)
        player.prepare()
        player.playWhenReady = autoplay
    }

    private fun articleResumeOffset(item: LibraryItem): Int = if (item.completed) 0 else
        (if (item.articleProgress != null) item.articleBookmark?.let { ArticleBookmark(it.textVersion, it.offsetUtf16) }
        else store.bookmark(item.id))?.takeIf { it.contentVersion == item.contentVersion }?.offsetUtf16 ?: 0

    private fun resumePosition(item: LibraryItem, audio: RenderedArticle?): Long {
        val saved = if (item.completed) 0 else if (audio != null) resumeAt(audio.chunks, if (item.articleProgress != null) item.articleBookmark?.let {
            ArticleBookmark(it.textVersion, it.offsetUtf16)
        } else store.bookmark(item.id), item.contentVersion)
        else if (item.episodeId != null) localPodcastPositions[item.id] ?: item.remotePositionMs else store.position(item.id)
        return resumeFrom(saved, if (audio == null) item.durationSeconds?.let { it * 1000L } else null)
    }

    private fun adopt(item: LibraryItem, audio: RenderedArticle?): MediaItem {
        persist()
        player.stop()
        if (rendered !== audio) rendered?.close()
        rendered = audio
        current = item
        currentOwner = library.state.value.owner
        store.saveRestoration(currentOwner, item.id)
        playbackRevision = library.state.value.revision
        hasPlayed = false
        progressPlaybackId = null
        beginProgressIntent(item, resumePosition(item, audio), audio?.let { bookmarkAt(it.chunks, resumePosition(item, it), item.contentVersion)?.offsetUtf16 })
        player.setPlaybackSpeed(store.speed(item.kind))
        store.lastItem = item.id
        store.saveContinuation(library.state.value.owner, item.id)
        val uri = audio?.uri ?: item.audioUrl ?: "asset:///welcome.wav"
        return MediaLibraryCatalog.media(item).buildUpon().setUri(uri).build()
    }

    private fun beginProgressIntent(item: LibraryItem? = current, position: Long = player.currentPosition, articleOffset: Int? = null) {
        if (item == null || !library.usesGuardedProgress(item)) return
        val latest = if (item.kind == ContentKind.Article) item else
            library.state.value.items.firstOrNull { it.id == item.id } ?: return
        val offset = articleOffset ?: rendered?.let { it.playerBookmark(player.currentTimeline, position, item.contentVersion).offsetUtf16 } ?: 0
        val version = playbackRevision
        val id = java.util.UUID.randomUUID().toString()
        progressPlaybackId = id
        (application as MagpieApplication).progressWork {
            if (version == library.state.value.revision) try {
                if (item.kind == ContentKind.Article) library.beginArticleProgress(latest, id, offset)
                else library.beginPodcastProgress(latest, id, position.coerceAtLeast(0) / 1000.0)
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (_: Exception) { progressError(version) }
        }
    }

    private fun progressError(version: Int) {
        if (version == library.state.value.revision) PlaybackStatus.mutable.value = PlaybackStatus.state.value.copy(
            error = "Listening progress could not be synced. Please check your connection and available storage.")
    }

    private fun persist(completed: Boolean = false) {
        val item = current ?: return
        if (item.kind == ContentKind.Podcast) {
            val position = if (completed) 0 else player.currentPosition.coerceAtLeast(0)
            store.savePosition(item.id, position)
            if (item.episodeId != null) localPodcastPositions[item.id] = position
        }
        else rendered?.let { audio ->
            audio.playerBookmark(player.currentTimeline, if (completed) 0 else player.currentPosition, item.contentVersion).let { store.saveBookmark(item.id, it) }
        }
        if (library.usesGuardedProgress(item)) {
            val id = progressPlaybackId ?: return
            if (!hasPlayed || voiceHold != null || item.id in uncertainProgress) return
            val version = playbackRevision
            val seconds = player.currentPosition.coerceAtLeast(0) / 1000.0
            val offset = if (completed) item.text.length else rendered?.let {
                it.playerBookmark(player.currentTimeline, player.currentPosition, item.contentVersion).offsetUtf16
            } ?: 0
            val send = completed || !player.isPlaying || SystemClock.elapsedRealtime() - lastReportedAt >= 30_000
            if (send) lastReportedAt = SystemClock.elapsedRealtime()
            // Application ownership lets the final disk write outlive service teardown.
            (application as MagpieApplication).progressWork {
                if (version == library.state.value.revision) try {
                    if (item.kind == ContentKind.Article) library.recordArticleProgress(item, id, offset, completed)
                    else library.recordPodcastProgress(item, id, seconds, completed)
                    if (send) library.flushProgress()
                } catch (cancelled: CancellationException) { throw cancelled }
                catch (_: Exception) { progressError(version) }
            }
            return
        }
        if (voiceHold == null && item.id !in uncertainProgress && item.episodeId != null && item.kind == ContentKind.Podcast && playbackRevision == library.state.value.revision &&
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
        else if (!library.usesGuardedProgress(item)) {
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
        store.saveContinuation(library.state.value.owner, null)
        dismissPlayer()
        feedback.finished()
    }

    private fun dismissPlayer() {
        cancelRestoration(forget = true)
        if (current != null) store.saveRestoration(currentOwner, null)
        cancelAssistant()
        invalidateVoice()
        // Keep each item's bookmark, but forget what to restore into the mini player.
        persist(completed = player.playbackState == Player.STATE_ENDED)
        rendering?.cancel()
        // As on iOS, finishing or closing leaves a running sleep timer counting; if nothing is
        // playing when it expires, it does nothing.
        PlaybackStatus.mutable.value = Preparation()
        current = null
        store.lastItem = null
        player.stop()
        player.clearMediaItems()
        rendered?.close()
        rendered = null
        PlaybackStatus.mutableReadingPosition.value = null
    }

    private fun publishReadingPosition() {
        val item = current
        val audio = rendered
        val active = item != null && audio != null && item.kind == ContentKind.Article &&
            player.currentMediaItem?.mediaId == item.id && player.playbackState != Player.STATE_IDLE &&
            player.playbackState != Player.STATE_ENDED && PlaybackStatus.state.value.message == null
        val range = if (active) {
            val index = player.currentPeriodIndex.coerceIn(audio.textChunks.indices)
            val chunk = audio.playerChunk(player.currentTimeline, index)
            readingRangeAt(listOf(chunk), audio.ranges(index).map { it.copy(startMs = it.startMs + chunk.startMs) }, player.currentPosition)
        } else null
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
            cancelRestoration()
            cancelAssistant()
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
            if (args.getBoolean("resume", true) && hold.resume && item != null) play(item, newIntent = false)
            return SessionResult(SessionResult.RESULT_SUCCESS)
        }
        val result = Bundle()
        when (args.getString("action")) {
            "drain" -> {
                val request = args.getString("request_id") ?: hold.token
                if (!request.matches(Regex("[a-zA-Z0-9-]{1,64}"))) return SessionResult(SessionError.ERROR_BAD_VALUE)
                hold.requests += request
                listOfNotNull(current, hold.item).forEach {
                    uncertainProgress.getOrPut(it.id) { mutableSetOf() }.add(request)
                }
            }
            "confirm" -> {
                val request = args.getString("request_id")
                if (request == null || request !in hold.requests) return SessionResult(SessionError.ERROR_BAD_VALUE)
                uncertainProgress.values.forEach { it.remove(request) }
                uncertainProgress.entries.removeAll { it.value.isEmpty() }
                hold.requests.remove(request)
            }
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
                if (store.speed(kind) != rate) automationSpeedUndo = com.henrydashwood.magpie.data.AccountLibrary.SpeedUndo(library.state.value.owner,
                    library.state.value.revision, kind, store.speed(kind), rate, SystemClock.elapsedRealtime() + 600_000)
                store.saveSpeed(kind, rate)
                if (current?.kind == kind) player.setPlaybackSpeed(rate)
            }
            "sleep" -> if (!setSleepTimer(args.getLong(SLEEP_DURATION_MS))) return SessionResult(SessionError.ERROR_BAD_VALUE)
            "cancel_sleep" -> cancelSleepTimer()
            "restore" -> {
                val item = library.state.value.items.find { it.id == args.getString("id") }
                item?.let { uncertainProgress.remove(it.id) }
                if (item != null && args.getBoolean("reset_bookmark")) {
                    filedArticleBookmarks.remove(item.id)
                    store.clearBookmark(item.id)
                    store.savePosition(item.id, 0)
                }
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
                if (store.restoration(library.state.value.owner) == id) store.saveRestoration(library.state.value.owner, null)
                uncertainProgress.remove(id)
                val item = library.state.value.items.find { it.id == id }
                if (item?.kind == ContentKind.Article) {
                    // Keep the bookmark for Undo even when a receipt is replayed after cancellation.
                    store.bookmark(item.id)?.let { filedArticleBookmarks[item.id] = it }
                }
                if (item?.completed == true) {
                    store.clearBookmark(item.id); store.savePosition(item.id, 0)
                    localPodcastPositions[item.id] = 0
                    if (store.continuation(library.state.value.owner) == item.id) store.saveContinuation(library.state.value.owner, null)
                }
                if (current?.id == id || hold.item?.id == id) {
                    hold.resume = false
                    // The server already filed it. Never report the old clock as unplayed.
                    rendering?.cancel(); current = null; store.lastItem = null
                    player.stop(); player.clearMediaItems()
                    rendered?.close(); rendered = null
                    PlaybackStatus.mutable.value = Preparation()
                    cancelSleepTimer()
                }
            }
            else -> return SessionResult(SessionError.ERROR_NOT_SUPPORTED)
        }
        return SessionResult(SessionResult.RESULT_SUCCESS, result)
    }

    /** Commands from our AppFunction service are checked again at the player boundary. */
    private fun automationCommand(controller: MediaSession.ControllerInfo, args: Bundle): ListenableFuture<SessionResult> {
        fun result(code: Int, message: String) = Futures.immediateFuture(SessionResult(code, Bundle().apply { putString("error", message) }))
        val state = library.state.value
        if (args.getString("owner") != (state.owner ?: "sample") || args.getInt("revision", -1) != state.revision)
            return result(SessionError.ERROR_PERMISSION_DENIED, "The account changed. Open Magpie and try again.")
        if (args.containsKey("expected_controls") && args.getInt("expected_controls") != PlaybackStatus.controlVersion.value)
            return result(SessionError.ERROR_INVALID_STATE, "Playback changed. Ask again when you are ready.")
        val action = args.getString("action")
        if (action == "status") return Futures.immediateFuture(SessionResult(SessionResult.RESULT_SUCCESS, automationSnapshot()))
        if (action == "play_item") {
            val id = args.getString("item_id").orEmpty()
            val prefix = "${state.owner}:episode:"
            if (if (state.live) !id.startsWith(prefix) || id.removePrefix(prefix).toIntOrNull()?.let { it > 0 } != true
                else state.items.none { it.id == id })
                return result(SessionError.ERROR_BAD_VALUE, "That item belongs to another account. Find it again.")
        }
        if (action == "latest" && args.getString("show_id")?.let { id -> state.feeds.none { "${state.owner}:feed:${it.id}" == id } } == true)
            return result(SessionError.ERROR_BAD_VALUE, "That show belongs to another account or is no longer followed.")
        if (action in setOf("play_item", "continue", "latest")) return startAutomation(controller, args)
        val value = args.getDouble("value", Double.NaN)
        if (current != null && playbackRevision != state.revision)
            return result(SessionError.ERROR_PERMISSION_DENIED, "The account changed. Open Magpie and try again.")
        val invalid = when (action) {
            "skip" -> !value.isFinite() || value !in -86_400.0..86_400.0
            "seek" -> !value.isFinite() || value !in 0.0..86_400.0
            "speed" -> !value.isFinite() || value !in 0.5..3.0
            "sleep" -> !value.isFinite() || value !in 1.0..1440.0
            "pause", "cancel_sleep", "undo_speed" -> false
            else -> true
        }
        if (invalid) return result(SessionError.ERROR_BAD_VALUE, "Choose a valid playback setting.")
        if (action !in setOf("cancel_sleep", "undo_speed") && current == null && !(action == "pause" && assistantFuture != null))
            return result(SessionError.ERROR_INVALID_STATE, "Nothing is loaded. Continue listening first.")
        if (action in setOf("skip", "seek") && player.duration <= 0)
            return result(SessionError.ERROR_INVALID_STATE, "The listening position is not available yet.")
        if (action == "undo_speed") {
            val undo = automationSpeedUndo
            if (undo == null || undo.revision != state.revision || undo.owner != state.owner || SystemClock.elapsedRealtime() >= undo.expiresAt)
                return result(SessionError.ERROR_INVALID_STATE, "There is no recent assistant speed change to undo.")
            if (store.speed(undo.kind) != undo.after) {
                automationSpeedUndo = null
                return result(SessionError.ERROR_INVALID_STATE, "Playback speed has changed since then. I left it as it is.")
            }
        }
        PlaybackStatus.mutableControlVersion.value++
        cancelAssistant(); invalidateVoice()
        when (action) {
            "pause" -> { rendering?.cancel(); PlaybackStatus.mutable.value = Preparation(); player.pause(); persist() }
            "skip", "seek" -> {
                val position = (value * 1000).toLong() + if (action == "skip") player.currentPosition else 0
                player.seekTo(position.coerceIn(0, player.duration)); persist()
            }
            "speed" -> {
                val kind = checkNotNull(current).kind
                val rate = value.toFloat()
                if (store.speed(kind) != rate) automationSpeedUndo = com.henrydashwood.magpie.data.AccountLibrary.SpeedUndo(state.owner, state.revision, kind, store.speed(kind), rate, SystemClock.elapsedRealtime() + 600_000)
                store.saveSpeed(kind, rate); player.setPlaybackSpeed(rate)
            }
            "undo_speed" -> {
                val undo = checkNotNull(automationSpeedUndo); automationSpeedUndo = null
                store.saveSpeed(undo.kind, undo.before)
                if (current?.kind == undo.kind) player.setPlaybackSpeed(undo.before)
            }
            "sleep" -> setSleepTimer(kotlin.math.ceil(value).toLong() * 60_000)
            "cancel_sleep" -> cancelSleepTimer()
        }
        return Futures.immediateFuture(SessionResult(SessionResult.RESULT_SUCCESS, automationSnapshot()))
    }

    private fun automationSnapshot(): Bundle {
        val item = current?.takeIf { playbackRevision == library.state.value.revision }
        return Bundle().apply {
            putString("item_id", item?.id)
            putBoolean("playing", item != null && player.isPlaying)
            putDouble("position", if (item != null) player.currentPosition.coerceAtLeast(0) / 1000.0 else 0.0)
            if (item != null && player.duration > 0) putDouble("remaining", (player.duration - player.currentPosition).coerceAtLeast(0) / 1000.0)
            putDouble("speed", player.playbackParameters.speed.toDouble())
            if (playbackRevision == library.state.value.revision)
                sleepTimer.state.deadlineMs?.let { putLong("sleep_end", System.currentTimeMillis() + (it - SystemClock.elapsedRealtime()).coerceAtLeast(0)) }
        }
    }

    private suspend fun resolveAutomation(args: Bundle): LibraryItem {
        val state = library.state.value
        val id = when (args.getString("action")) {
            "play_item" -> args.getString("item_id") ?: throw IllegalArgumentException("Choose an item to play.")
            "continue" -> current?.takeIf { playbackRevision == state.revision }?.id ?: store.continuation(state.owner)
                ?: throw IllegalArgumentException("There is nothing to continue. Choose an item first.")
            else -> {
                val show = args.getString("show_id")?.let { id -> state.feeds.firstOrNull { "${state.owner}:feed:${it.id}" == id }
                    ?: throw IllegalArgumentException("That show belongs to another account or is no longer followed.") }
                library.shortcutItems(show?.id, limit = 100).firstOrNull { !it.completed && !it.dismissed && it.captureError == null }?.id
                    ?: throw IllegalArgumentException("There is nothing new to listen to.")
            }
        }
        return catalog.resolve(MediaItem.Builder().setMediaId(id).build())
    }

    private fun startAutomation(controller: MediaSession.ControllerInfo, args: Bundle): ListenableFuture<SessionResult> {
        val prepared = prepareAssistant(controller, listOf(MediaItem.EMPTY), 0, C.TIME_UNSET) { resolveAutomation(args) }
        val pending = AutomationPlayback(controller, library.state.value.revision, PlaybackStatus.controlVersion.value)
        automationPlayback = pending
        pending.job = scope.launch(start = CoroutineStart.LAZY) {
            fun checkRequest() {
                if (automationPlayback !== pending || pending.revision != library.state.value.revision || pending.controls != PlaybackStatus.controlVersion.value)
                    throw CancellationException("Listening request changed")
            }
            try {
                withTimeout(145_000) {
                    val media = awaitPrepared(prepared)
                    checkRequest()
                    player.setMediaItem(media.mediaItems.single(), media.startPositionMs)
                    pending.applied = true
                    player.prepare(); player.play()
                    withTimeout(15_000) {
                        while (!player.isPlaying || !isPlaybackOngoing) {
                            checkRequest()
                            if (pending.foregroundDenied) break
                            player.playerError?.let { throw it }
                            delay(25)
                        }
                    }
                    checkRequest()
                    val snapshot = automationSnapshot().apply { putBoolean("foreground_required", pending.foregroundDenied) }
                    automationPlayback = null
                    pending.result.set(SessionResult(SessionResult.RESULT_SUCCESS, snapshot))
                }
            } catch (failure: Exception) {
                if (automationPlayback === pending) {
                    automationPlayback = null
                    prepared.cancel(false)
                    if (pending.applied) { player.pause(); persist() }
                    pending.result.set(SessionResult(SessionError.ERROR_INVALID_STATE, Bundle().apply {
                        putBoolean("cancelled", failure is CancellationException && failure !is TimeoutCancellationException)
                        putString("error", if (failure is TimeoutCancellationException) "Playback took too long. Open Magpie and try again."
                            else com.henrydashwood.magpie.data.AccountLibrary.message(failure))
                    }))
                }
            }
        }
        pending.result.addListener({ if (pending.result.isCancelled && automationPlayback === pending) cancelAssistant() }, mainExecutor)
        pending.job.start()
        return pending.result
    }

    private suspend fun awaitPrepared(future: ListenableFuture<MediaSession.MediaItemsWithStartPosition>): MediaSession.MediaItemsWithStartPosition =
        kotlinx.coroutines.suspendCancellableCoroutine { continuation ->
            continuation.invokeOnCancellation { future.cancel(false) }
            // Preparation completes on the service's main dispatcher. Resume inline
            // so no independent control can land between adopting the item and
            // assigning its media to the player.
            future.addListener({
                if (continuation.isActive) try { continuation.resumeWith(Result.success(future.get())) }
                catch (failure: Exception) { continuation.resumeWith(Result.failure(failure.cause ?: failure)) }
            }, com.google.common.util.concurrent.MoreExecutors.directExecutor())
        }

    private fun cancelAutomation(preservePlayback: Boolean) {
        val pending = automationPlayback ?: return
        automationPlayback = null
        pending.job.cancel()
        if (pending.applied && !preservePlayback) { player.pause(); persist() }
        pending.result.set(SessionResult(SessionError.ERROR_INVALID_STATE, Bundle().apply {
            putBoolean("cancelled", true); putString("error", "Listening request changed.")
        }))
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
        cancelAssistant()
        PlaybackStatus.mutableControlVersion.value++
        invalidateVoice()
        val wasPlaying = player.isPlaying
        // Also stop buffering or narration preparation so it cannot start after the deadline.
        rendering?.cancel()
        PlaybackStatus.mutable.value = Preparation()
        player.pause()
        persist()
        if (wasPlaying) feedback.finished()
    }

    private fun trusted(controller: MediaSession.ControllerInfo) = controller.uid == applicationInfo.uid || controller.isTrusted
    // Legacy browser binding supplies an anonymous placeholder here. The real
    // caller is checked in onConnect before any library or player access.
    override fun onGetSession(controllerInfo: MediaSession.ControllerInfo): MediaLibrarySession? {
        val legacyBinding = controllerInfo.uid < 0 &&
            controllerInfo.controllerVersion == MediaSession.ControllerInfo.LEGACY_CONTROLLER_VERSION &&
            controllerInfo.packageName == MediaSession.ControllerInfo.LEGACY_CONTROLLER_PACKAGE_NAME
        return if (trusted(controllerInfo) || legacyBinding) session else null
    }

    override fun onDestroy() {
        cancelRestoration()
        cancelAssistant()
        unregisterReceiver(noisyReceiver)
        invalidateVoice()
        persist(completed = player.playbackState == Player.STATE_ENDED)
        cancelSleepTimer()
        feedback.close()
        scope.cancel()
        renderer.close()
        session.release()
        player.release()
        rendered?.close()
        PlaybackStatus.mutable.value = Preparation()
        PlaybackStatus.mutableReadingPosition.value = null
        super.onDestroy()
    }

    companion object {
        const val AUTOMATION_CONTROL = "magpie.automation_control"
        const val BEGIN_VOICE = "magpie.begin_voice"
        const val END_VOICE = "magpie.end_voice"
        const val VOICE_CONTROL = "magpie.voice_control"
        const val RESTORE_PLAYER = "magpie.restore_player"
        const val PLAY_ITEM = "magpie.play_sample"
        const val DISMISS_PLAYER = "magpie.dismiss_player"
        const val CANCEL_PREPARATION = "magpie.cancel_preparation"
        const val SET_SLEEP_TIMER = "magpie.set_sleep_timer"
        const val CANCEL_SLEEP_TIMER = "magpie.cancel_sleep_timer"
        const val SLEEP_DURATION_MS = "duration_ms"
    }
}
