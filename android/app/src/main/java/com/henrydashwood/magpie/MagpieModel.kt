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
import com.henrydashwood.magpie.data.ItemFiling
import com.henrydashwood.magpie.data.ItemFilingAction
import com.henrydashwood.magpie.data.PreviewStore
import com.henrydashwood.magpie.playback.PlaybackService
import com.henrydashwood.magpie.playback.PlaybackStatus
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withTimeout
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import com.henrydashwood.magpie.voice.*
import com.henrydashwood.magpie.shortcuts.*
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.TimeoutCancellationException

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
    private val repository = (application as MagpieApplication).library
    private val mutableSubscriptionExport = MutableStateFlow<com.henrydashwood.magpie.data.SubscriptionExportFile?>(null)
    val pendingSubscriptionExport = mutableSubscriptionExport.asStateFlow()
    suspend fun exportSubscriptions() {
        val owner = repository.state.value.let { it.owner to it.revision }
        val xml = repository.exportSubscriptions()
        if (owner == repository.state.value.let { it.owner to it.revision }) {
            mutableSubscriptionExport.value = com.henrydashwood.magpie.data.SubscriptionExportFile(owner, xml)
        }
    }
    fun clearSubscriptionExport() { mutableSubscriptionExport.value = null }
    val subscriptionImport = com.henrydashwood.magpie.data.SubscriptionImportController(viewModelScope, repository)
    val discovery = com.henrydashwood.magpie.data.SourceDiscovery(viewModelScope, repository)
    suspend fun aiConsent() = repository.aiConsent()
    suspend fun setAIConsent(granted: Boolean) = repository.setAIConsent(granted)
    val libraryState = repository.state
    val library get() = libraryState.value.items
    private val mutableItemLoading = MutableStateFlow<String?>(null)
    val itemLoading = mutableItemLoading.asStateFlow()
    private val mutableItemError = MutableStateFlow<String?>(null)
    val itemError = mutableItemError.asStateFlow()
    private var contentJob: Job? = null
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
    private val inbox = (application as MagpieApplication).deviceLinkInbox
    private val mutableDeviceLinks = MutableStateFlow(inbox.links())
    val deviceLinks = mutableDeviceLinks.asStateFlow()
    private val mutableImportingLinks = MutableStateFlow(false)
    val importingLinks = mutableImportingLinks.asStateFlow()
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
    fun listeningPresentation(item: LibraryItem, playback: PlayerState = player.value): com.henrydashwood.magpie.data.ListeningPresentation {
        val current = playback.item?.id == item.id && playback.durationMs > 0
        val live = libraryState.value.live
        val offset = PlaybackStatus.readingPosition.value?.takeIf { current && it.itemId == item.id && it.contentVersion == item.contentVersion }?.startUtf16
            ?: if (live) item.articleBookmark?.offsetUtf16 ?: 0 else store.bookmark(item.id)?.takeIf { it.contentVersion == item.contentVersion }?.offsetUtf16 ?: 0
        return com.henrydashwood.magpie.data.listeningPresentation(item,
            positionMs = if (current) playback.positionMs else if (live) item.remotePositionMs else store.position(item.id),
            durationMs = if (current && item.kind == ContentKind.Podcast) playback.durationMs else (item.durationSeconds?.toLong() ?: 0) * 1_000,
            completed = if (current && playback.positionMs > 0) false else item.id in finished.value,
            articleOffset = offset)
    }
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
    val newsletters = com.henrydashwood.magpie.data.Newsletters(viewModelScope, repository) { mutableNotice.value = it }
    val sourceManager = com.henrydashwood.magpie.data.SourceManager(viewModelScope, repository) { mutableNotice.value = it }
    val savedPreparation = com.henrydashwood.magpie.data.SavedPreparation(viewModelScope, repository,
        (application as MagpieApplication).articleInbox, { mutableNotice.value = it }, { before, after ->
            if (before.contentId != after.contentId) store.clearBookmark(before.id)
        })
    private var controller: MediaController? = null
    private val connection = MediaController.Builder(application, SessionToken(application, ComponentName(application, PlaybackService::class.java))).buildAsync()
    val speechInput by lazy { (getApplication<Application>() as MagpieApplication).voiceInput() }
    private val mutableConversationSettings = MutableStateFlow(store.conversation)
    val diagnosticsEnabled get() = (getApplication<Application>() as MagpieApplication).diagnosticsEnabled
    fun setDiagnosticsEnabled(enabled: Boolean) = (getApplication<Application>() as MagpieApplication).setDiagnosticsEnabled(enabled)
    val conversationSettings = mutableConversationSettings.asStateFlow()
    fun setConversationPreferences(value: ConversationPreferences) { store.conversation = value; mutableConversationSettings.value = value }
    val voice by lazy {
        VoiceSession(viewModelScope, PlaybackVoiceHost(repository, store, { player.value.item }, {
            contentJob?.cancel(); voiceCatalog.stop(); voiceRefresh?.cancel()
        }, ::voiceCommand), speechInput,
            (getApplication<Application>() as MagpieApplication).voiceOutput { store.voiceId }, { store.conversation }, repository.voiceConversation, com.henrydashwood.magpie.telemetry.LibraryVoiceTelemetry(repository))
    }
    val newsletterSpeech by lazy {
        com.henrydashwood.magpie.voice.SpokenInformation(viewModelScope,
            PlaybackVoiceHost(repository, store, { player.value.item }, { voiceCatalog.stop(); voiceRefresh?.cancel(); contentJob?.cancel() }, ::voiceCommand),
            (getApplication<Application>() as MagpieApplication).voiceOutput { store.voiceId }, repository.voiceConversation) {
                mutableNotice.value = it
            }
    }
    val itemFiling by lazy {
        ItemFiling(viewModelScope, repository,
            PlaybackVoiceHost(repository, store, { player.value.item }, {
                voiceCatalog.stop(); voiceRefresh?.cancel(); contentJob?.cancel()
            }, ::voiceCommand, resetRestoredBookmark = true)) { mutableNotice.value = it }
    }
    fun readNewsletterAddress(spell: Boolean) {
        val state = newsletters.state.value
        val address = state.address ?: return
        if (!libraryState.value.live || state.revision != libraryState.value.revision) return
        newsletterSpeech.speak(if (spell) "Your newsletter address is spelled ${address.spelledOut}" else "Your newsletter address is ${address.spoken}")
    }
    private suspend fun voiceCommand(action: String, args: Bundle): Bundle {
        val media = controller?.takeIf { it.isConnected } ?: throw VoiceFailure("The player is still connecting. Please try again.")
        val result = withTimeout(if (args.getString("action") == "drain") 30_000 else 5_000) {
            suspendCancellableCoroutine<androidx.media3.session.SessionResult> { continuation ->
                val future = media.sendCustomCommand(SessionCommand(action, Bundle.EMPTY), args)
                future.addListener({
                    if (continuation.isActive) try { continuation.resume(future.get()) }
                    catch (failure: Exception) { continuation.resumeWithException(failure) }
                }, getApplication<Application>().mainExecutor)
            }
        }
        if (result.resultCode < 0) throw VoiceFailure("Playback changed or is not ready for that request. Please try again.")
        updatePlayer()
        return result.extras
    }

    init {
        viewModelScope.launch {
            var revision = -1
            repository.state.collect { snapshot ->
                voice.activate()
                if (revision != snapshot.revision) {
                    revision = snapshot.revision
                    clearSubscriptionExport()
                    discovery.reset()
                    newsletters.reset(snapshot.revision)
                    newsletterSpeech.stop(resume = false)
                    sourceManager.reset()
                    contentJob?.cancel()
                    mutableItemLoading.value = null
                    mutableItemError.value = null
                    mutableLinkCapture.value = LinkCaptureState()
                    mutableSourceCapture.value = LinkCaptureState()
                    mutableNotice.value = null
                    itemFiling.reset()
                    mutableClearingLatest.value = false
                    mutableClearLatestError.value = null
                    mutableImportingLinks.value = false
                }
                mutableSaved.value = if (snapshot.live) snapshot.savedIds.toSet() else store.saved
                mutableFinished.value = if (snapshot.live) snapshot.items.filter { it.completed }.map { it.id }.toSet() else store.finished
                mutableDismissedFromLatest.value = if (snapshot.live) emptySet() else store.dismissedFromLatest
                mutablePendingLinks.value = if (snapshot.live) emptyList() else inbox.links()
                mutableDeviceLinks.value = inbox.links()
                mutablePendingSources.value = if (snapshot.live) emptyList() else sourceInbox.links()
                savedPreparation.activate(if (snapshot.live) snapshot.owner else null, snapshot.revision)
                updatePlayer()
            }
        }
        connection.addListener({
            try {
                controller = connection.get().also { media ->
                    media.addListener(object : Player.Listener {
                        override fun onEvents(player: Player, events: Player.Events) { updatePlayer() }
                    })
                }
                controller?.sendCustomCommand(SessionCommand(PlaybackService.RESTORE_PLAYER, Bundle.EMPTY), Bundle.EMPTY)
                updatePlayer()
            } catch (_: Exception) { mutableNotice.value = "The player could not connect. Close and reopen Magpie to try again." }
        }, application.mainExecutor)
        viewModelScope.launch { while (isActive) { delay(500); updatePlayer() } }
        viewModelScope.launch { PlaybackStatus.voiceToken.collect { voice.playbackChanged(it); newsletterSpeech.playbackChanged(it) } }
    }

    private fun updatePlayer() {
        mutableSettings.value = readSettings()
        // Playback can finish in the service while the activity is backgrounded.
        if (!libraryState.value.live) mutableFinished.value = store.finished
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

    fun refreshLibrary() { if (libraryState.value.live) { newsletters.loadPending(); viewModelScope.launch { repository.refresh(); savedPreparation.sync() } } }
    private var shortcutJob: kotlinx.coroutines.Job? = null
    private var shortcutVersion = 0
    private val mutableShortcutWorking = MutableStateFlow<String?>(null)
    val shortcutWorking = mutableShortcutWorking.asStateFlow()
    private val mutableShortcutNavigation = MutableStateFlow<ShortcutRequest?>(null)
    val shortcutNavigation = mutableShortcutNavigation.asStateFlow()
    fun consumeShortcutNavigation() { mutableShortcutNavigation.value = null }
    fun cancelShortcut() { shortcutVersion++; shortcutJob?.cancel(); shortcutJob = null; mutableShortcutWorking.value = null }
    fun runShortcut(request: ShortcutRequest) {
        cancelShortcut()
        val version = shortcutVersion
        val controls = PlaybackStatus.controlVersion.value
        val initial = libraryState.value
        mutableNotice.value = null
        mutableShortcutWorking.value = request.action.label
        shortcutJob = viewModelScope.launch {
            try {
                withTimeout(30_000) {
                    fun checkScope() {
                        check(libraryState.value.revision == initial.revision && libraryState.value.live == initial.live) { "Your account changed. Open the shortcut again." }
                        check(request.owner == null || request.owner == (libraryState.value.owner ?: if (!libraryState.value.live) "sample" else null)) { "This shortcut belongs to another account. Sign in to that account or create a new shortcut." }
                    }
                    // A delayed assistant handoff must be validated before it can
                    // close a conversation, change a screen, or prepare content.
                    if (request.owner != null) libraryState.first { !it.loading }
                    checkScope()
                    if (request.action == ShortcutAction.RunRequest) {
                        val context = repository.voiceConversation
                        check(!context.executing) { "Magpie is already handling a request. Let it finish, then continue in Ask Magpie." }
                        val state = libraryState.value
                        val pending = repository.voiceHandoffs.consume(checkNotNull(request.handoffId),
                            "${state.revision}:${state.owner}:${state.live}", context.generation(), context.pending?.requestId)
                        contentJob?.cancel()
                        mutableShortcutNavigation.value = request
                        voice.continueRequest(pending)
                        return@withTimeout
                    }
                    contentJob?.cancel()
                    if (request.action in setOf(ShortcutAction.Ask, ShortcutAction.Saved, ShortcutAction.Following, ShortcutAction.OpenLatest, ShortcutAction.Shortcuts, ShortcutAction.Player)) {
                        voice.close(resume = false)
                        mutableShortcutNavigation.value = request
                        if (request.action == ShortcutAction.Ask) voice.open(null, listenOnOpen = request.listenOnOpen)
                        return@withTimeout
                    }
                    val snapshot = libraryState.first { !it.loading }
                    fun checkAccount() {
                        checkScope()
                        check(PlaybackStatus.controlVersion.value == controls) { "Playback changed. Open the shortcut again when you are ready." }
                    }
                    checkAccount()
                    check(!snapshot.live || snapshot.owner != null) { "Your library could not load. Open Magpie and try again." }
                    if (request.action == ShortcutAction.OpenFeed) {
                        check(snapshot.feeds.any { it.id == request.feedId }) { "That show is no longer followed. Find it again." }
                        voice.close(resume = false)
                        mutableShortcutNavigation.value = request
                        return@withTimeout
                    }
                    player.first { it.connected }
                    checkAccount()
                    val item = when (request.action) {
                        ShortcutAction.Continue -> player.value.item ?: (store.continuation(snapshot.owner) ?: store.lastItem)?.let { repository.shortcutItem(it) }
                            ?: throw IllegalStateException("There is nothing to continue yet. Choose Play latest or open an item first.")
                        ShortcutAction.ReadItem, ShortcutAction.PlayItem -> repository.shortcutItem(checkNotNull(request.itemId))
                        ShortcutAction.Latest, ShortcutAction.PlayFeed -> repository.shortcutItems(request.feedId).firstOrNull {
                            !it.completed && !it.dismissed && it.captureError == null && (snapshot.live || it.id !in finished.value && it.id !in dismissedFromLatest.value)
                        } ?: throw IllegalStateException("There is nothing new to listen to here.")
                        else -> return@withTimeout
                    }
                    checkAccount()
                    val loaded = if (item.textLoaded) item else repository.content(item.id)
                    checkAccount()
                    voice.close(resume = false)
                    mutableShortcutNavigation.value = request.copy(itemId = loaded.id)
                    if (request.action != ShortcutAction.ReadItem) playReady(loaded)
                }
            } catch (_: TimeoutCancellationException) {
                mutableNotice.value = "That shortcut took too long. Open Magpie and try again."
            } catch (cancelled: CancellationException) { throw cancelled
            } catch (failure: Exception) {
                mutableNotice.value = failure.message ?: "That shortcut could not finish. Please try again."
            } finally { if (version == shortcutVersion) mutableShortcutWorking.value = null }
        }
    }
    /** The microphone buttons open straight into listening, as on iOS. */
    fun ask(viewedEpisodeId: Int? = null, listen: Boolean = true) { cancelShortcut(); voice.open(viewedEpisodeId, listenOnOpen = listen) }
    suspend fun searchLibrary(feedId: String?, query: String) {
        if (libraryState.value.live && libraryState.value.owner != null) repository.search(feedId, query)
    }
    fun openItem(item: LibraryItem, play: Boolean = false) {
        if (play) { cancelShortcut(); voice.close(resume = false) }
        contentJob?.cancel()
        mutableItemError.value = null
        if (!libraryState.value.live || item.textLoaded) { if (play) playReady(item); return }
        mutableItemLoading.value = item.id
        contentJob = viewModelScope.launch {
            try {
                if (item.captureError != null && item.id in saved.value) repository.prepareSaved(item, false, libraryState.value.revision)
                val loaded = repository.content(item.id)
                if (play) playReady(loaded)
            }
            catch (cancelled: CancellationException) { throw cancelled }
            catch (failure: Exception) { mutableItemError.value = com.henrydashwood.magpie.data.AccountLibrary.message(failure) }
            finally { mutableItemLoading.value = null }
        }
    }
    fun play(item: LibraryItem) = openItem(item, play = true)
    private fun playReady(item: LibraryItem) {
        if (library.none { it.id == item.id }) return
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
        cancelShortcut()
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
        cancelShortcut()
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
        if (libraryState.value.live) {
            libraryAction { if (item.id in saved.value) repository.remove(item) else repository.save(item) }
            return
        }
        val next = if (item.id in saved.value) saved.value - item.id else saved.value + item.id
        store.saved = next
        mutableSaved.value = next
        mutableNotice.value = if (item.id in next) "Saved for later" else "Removed from Saved"
    }
    private fun libraryAction(action: suspend () -> Unit) {
        val revision = libraryState.value.revision
        viewModelScope.launch {
            try { action() }
            catch (cancelled: CancellationException) { throw cancelled }
            catch (failure: Exception) { if (revision == libraryState.value.revision)
                mutableNotice.value = com.henrydashwood.magpie.data.AccountLibrary.message(failure) }
        }
    }
    fun dismissNotice() { mutableNotice.value = null }

    fun clearLatest() {
        if (mutableClearingLatest.value) return
        mutableClearingLatest.value = true
        mutableClearLatestError.value = null
        val currentIds = library.map { it.id }.toSet()
        val revision = libraryState.value.revision
        viewModelScope.launch {
            try {
                if (libraryState.value.live) repository.clearLatest()
                else mutableDismissedFromLatest.value = withContext(Dispatchers.IO) { store.dismissFromLatest(currentIds) }
                mutableNotice.value = "Latest cleared"
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (error: Exception) { if (revision == libraryState.value.revision) mutableClearLatestError.value = "Latest could not be cleared. Please try again." }
            finally { if (revision == libraryState.value.revision) mutableClearingLatest.value = false }
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
        val revision = libraryState.value.revision
        viewModelScope.launch {
            try {
                if (libraryState.value.live) {
                    savedPreparation.add(capture.url)
                    if (revision != libraryState.value.revision) return@launch
                    mutableLinkCapture.value = LinkCaptureState(savedUrl = capture.url)
                    return@launch
                }
                val added = withContext(Dispatchers.IO) { inbox.add(capture.url) }
                mutablePendingLinks.value = inbox.links()
                mutableDeviceLinks.value = inbox.links()
                mutableLinkCapture.value = LinkCaptureState(savedUrl = capture.url)
                mutableNotice.value = if (added) "Link saved on this device" else "This link is already saved on this device"
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (error: Exception) { if (revision == libraryState.value.revision) mutableLinkCapture.update { it.copy(saving = false, error = error.message ?: "The link could not be saved. Please try again.") } }
        }
    }
    fun removePendingLink(url: String) {
        viewModelScope.launch {
            try {
                withContext(Dispatchers.IO) { inbox.remove(url) }
                mutablePendingLinks.value = inbox.links()
                mutableDeviceLinks.value = inbox.links()
                mutableNotice.value = "Saved link removed"
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (error: Exception) { mutableNotice.value = error.message ?: "The link could not be removed. Please try again." }
        }
    }

    fun importDeviceLinks() {
        if (!libraryState.value.live || mutableImportingLinks.value || savedPreparation.state.value.busy) return
        val revision = libraryState.value.revision
        val urls = deviceLinks.value.toList()
        mutableImportingLinks.value = true
        viewModelScope.launch {
            try {
                for (url in urls) {
                    if (revision != libraryState.value.revision) throw CancellationException("Account changed")
                    // Commit to the chosen account before removing the unassigned copy.
                    savedPreparation.add(url, syncAfter = false)
                    if (revision != libraryState.value.revision) throw CancellationException("Account changed")
                    withContext(Dispatchers.IO) { inbox.remove(url) }
                    if (revision != libraryState.value.revision) throw CancellationException("Account changed")
                    mutableDeviceLinks.value = inbox.links()
                }
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (failure: Exception) { if (revision == libraryState.value.revision) mutableNotice.value = failure.message ?: "The links could not be imported. Please try again." }
            finally { if (revision == libraryState.value.revision) { mutableImportingLinks.value = false; savedPreparation.sync() } }
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
        val revision = libraryState.value.revision
        viewModelScope.launch {
            try {
                if (libraryState.value.live) {
                    repository.subscribe(capture.url.trim())
                    mutableSourceCapture.value = LinkCaptureState(savedUrl = capture.url)
                    mutableNotice.value = "Added to Following"
                    return@launch
                }
                val added = withContext(Dispatchers.IO) { sourceInbox.add(capture.url) }
                mutablePendingSources.value = sourceInbox.links()
                mutableSourceCapture.value = LinkCaptureState(savedUrl = capture.url)
                mutableNotice.value = if (added) "Feed address saved on this device" else "This feed address is already saved on this device"
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (error: Exception) { if (revision == libraryState.value.revision) mutableSourceCapture.update { it.copy(saving = false, error = error.message ?: "The link could not be saved. Please try again.") } }
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
        fileItem(item, if (item.id in finished.value) ItemFilingAction.Restore else ItemFilingAction.Finish)
    }
    fun fileItem(item: LibraryItem, action: ItemFilingAction) {
        if (libraryState.value.live) { itemFiling.file(item, action); return }
        val revision = libraryState.value.revision
        libraryAction {
            fun checkSample() {
                if (libraryState.value.live || libraryState.value.revision != revision) throw CancellationException("Account changed")
            }
            checkSample()
            if (player.value.item?.id == item.id) voiceCommand(PlaybackService.DISMISS_PLAYER, Bundle.EMPTY)
            checkSample()
            withContext(Dispatchers.IO) { store.fileSample(item.id, action) }
            checkSample()
            mutableFinished.value = store.finished
            mutableDismissedFromLatest.value = store.dismissedFromLatest
            mutableNotice.value = when (action) {
                ItemFilingAction.Finish -> if (item.kind == ContentKind.Article) "Marked as read" else "Marked as played"
                ItemFilingAction.Restore -> "Restored"
                ItemFilingAction.Dismiss -> "Dismissed from Latest"
            } + ": ${item.title}"
        }
    }

    override fun onCleared() {
        itemFiling.reset()
        newsletterSpeech.stop(resume = false)
        voice.close(resume = false)
        closeVoiceSettings()
        MediaController.releaseFuture(connection)
    }
}
