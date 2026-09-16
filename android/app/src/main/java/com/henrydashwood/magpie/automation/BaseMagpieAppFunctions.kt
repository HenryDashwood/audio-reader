package com.henrydashwood.magpie.automation

import android.content.ComponentName
import android.app.PendingIntent
import android.os.Bundle
import androidx.annotation.RequiresApi
import androidx.appfunctions.*
import androidx.media3.session.MediaController
import androidx.media3.session.SessionToken
import androidx.media3.session.SessionCommand
import androidx.media3.session.SessionResult
import androidx.media3.session.SessionError
import com.henrydashwood.magpie.MagpieApplication
import com.henrydashwood.magpie.data.*
import com.henrydashwood.magpie.playback.PlaybackService
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.first
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/** An item in the current account's library. IDs must be passed back unchanged. */
@AppFunctionSerializable(isDescribedByKDoc = true)
data class ListeningItem(
    /** Account-scoped item ID. */ val id: String,
    /** Podcast episode or article title. */ val title: String,
    /** Show or publication name. */ val source: String,
    /** Either podcast or article. */ val kind: String,
    /** Whether the item has been completed. */ val completed: Boolean,
    /** Known content duration in seconds, or null when unknown. */ val durationSeconds: Int?,
)

/** A followed show or publication in the current account. */
@AppFunctionSerializable(isDescribedByKDoc = true)
data class FollowedShow(
    /** Account-scoped show ID. */ val id: String,
    /** Show or publication title. */ val title: String,
    /** Whether this publication supplies articles. */ val articles: Boolean,
)

/** A snapshot of Magpie's service-owned player. */
@AppFunctionSerializable(isDescribedByKDoc = true)
data class ListeningStatus(
    /** Loaded item, or null if nothing is loaded. */ val item: ListeningItem?,
    /** Whether audio is currently playing. */ val playing: Boolean,
    /** Current media position in seconds; article time belongs to this device's rendered audio. */ val positionSeconds: Double,
    /** Remaining content seconds, or null when duration is unknown. */ val remainingSeconds: Double?,
    /** Current playback speed multiplier. */ val speed: Double,
    /** Sleep timer end as Unix epoch milliseconds, or null when off. */ val sleepEndsAtMillis: Long?,
)

/** Confirmed playback status, or a foreground handoff when Android requires the user to open Magpie. */
@AppFunctionSerializable(isDescribedByKDoc = true)
data class ListeningStart(
    /** Service-confirmed listening state; never announce playback when playing is false. */ val status: ListeningStatus,
    /** Optional one-use action for opening Magpie to finish starting the selected item. */ val openMagpie: PendingIntent?,
)

/** Confirmed library result. An unavailable Undo returns changed=false and an explanation. */
@AppFunctionSerializable(isDescribedByKDoc = true)
data class LibraryChange(
    val changed: Boolean,
    val message: String,
    val item: ListeningItem?,
)

@RequiresApi(36)
@AppFunctionServiceEntryPoint(serviceName = "MagpieAppFunctions", appFunctionXmlFileName = "magpie_app_functions")
@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
abstract class BaseMagpieAppFunctions : AppFunctionService() {
    private val library get() = (application as MagpieApplication).library

    private suspend fun ready(waitForLibrary: Boolean = true): LibraryState {
        val revision = library.state.value.revision
        val state = if (waitForLibrary) library.state.first { !it.loading } else library.state.value
        if (state.revision != revision) throw CancellationException("Account changed")
        if (!state.live || state.owner == null) throw AppFunctionPermissionRequiredException("Open Magpie and sign in first.")
        return state
    }
    private fun checkAccount(state: LibraryState) {
        if (library.state.value.revision != state.revision || library.state.value.owner != state.owner)
            throw CancellationException("Account changed")
    }
    private suspend fun <T> action(timeoutMs: Long = 30_000, work: suspend () -> T): T = withContext(Dispatchers.Main.immediate) {
        try { withTimeout(timeoutMs) { work() } }
        catch (_: TimeoutCancellationException) { throw AppFunctionAppUnknownException("Magpie took too long. Open the app and try again.") }
        catch (failure: CancellationException) { throw failure }
        catch (failure: AppFunctionException) { throw failure }
        catch (failure: IllegalArgumentException) { throw AppFunctionInvalidArgumentException(failure.message) }
        catch (failure: Exception) { throw AppFunctionAppUnknownException(AccountLibrary.message(failure)) }
    }
    private fun item(value: LibraryItem) = ListeningItem(value.id, value.title, value.source,
        if (value.kind == ContentKind.Podcast) "podcast" else "article", value.completed, value.durationSeconds)
    private fun scopedShowId(state: LibraryState, feed: LibraryFeed) = "${state.owner}:feed:${feed.id}"

    /**
     * Lists followed shows and publications. Use the returned ID to restrict findItems to a show.
     * @param query Optional case-insensitive title match, up to 200 characters.
     * @return Followed shows belonging to the current account.
     */
    @AppFunction(isEnabled = false, isDescribedByKDoc = true)
    suspend fun listShows(query: String? = null): List<FollowedShow> = action {
        val search = query.orEmpty().trim()
        require(search.length <= 200) { "Choose a shorter show search." }
        val state = ready()
        state.feeds.filter { it.title.contains(search, ignoreCase = true) }
            .map { FollowedShow(scopedShowId(state, it), it.title, it.articles) }
    }

    /**
     * Finds podcasts and articles in the account library. Empty search and show select Latest.
     * Filters the first 100 candidates, newest first for Latest/shows or by search relevance.
     * This is read-only: it does not mark, dismiss, save, or play any item.
     * @param query Title/content search, up to 200 characters.
     * @param showId Optional unchanged ID returned by listShows.
     * @param unheardOnly Exclude completed items when true; defaults to false.
     * @param maximumMinutes Optional duration ceiling from zero to 1440 minutes. Items with unknown durations are excluded when supplied.
     * @param maxResults Number of results, from one to 100; defaults to 20.
     * @return Matching items, newest/relevance order, with account-scoped IDs.
     */
    @AppFunction(isEnabled = false, isDescribedByKDoc = true)
    suspend fun findItems(query: String? = null, showId: String? = null, unheardOnly: Boolean? = null,
        maximumMinutes: Double? = null, maxResults: Int? = null): List<ListeningItem> = action {
        val search = query.orEmpty().trim()
        val count = maxResults ?: 20
        require(search.length <= 200 && count in 1..100) { "Choose a search up to 200 characters and one to 100 results." }
        require(maximumMinutes == null || maximumMinutes.isFinite() && maximumMinutes in 0.0..1440.0) { "Choose a duration from zero to 24 hours." }
        val state = ready()
        val feed = showId?.let { id -> state.feeds.firstOrNull { scopedShowId(state, it) == id }
            ?: throw AppFunctionElementNotFoundException("That show belongs to another account or is no longer followed. List shows again.") }
        val matches = library.shortcutItems(feed?.id, search, limit = 100)
        checkAccount(state)
        matches.filter { (unheardOnly != true || !it.completed) && (maximumMinutes == null ||
            it.durationSeconds?.let { seconds -> seconds > 0 && seconds <= maximumMinutes * 60 } == true) }
            .take(count).map(::item)
    }

    /** Returns the current item, playing state, position, speed, remaining content, and sleep timer without changing playback. */
    @AppFunction(isEnabled = false, isDescribedByKDoc = true)
    suspend fun getListeningStatus(): ListeningStatus = control("status")

    /** Pauses listening and cancels any pending listening preparation. */
    @AppFunction(isEnabled = false, isDescribedByKDoc = true)
    suspend fun pauseListening(): ListeningStatus = control("pause")

    /**
     * Skips within the loaded item, preserving whether it is playing or paused.
     * @param seconds Signed duration in seconds, from -86400 to 86400; negative moves backward. Defaults to 30 seconds forward.
     */
    @AppFunction(isEnabled = false, isDescribedByKDoc = true)
    suspend fun skipListening(seconds: Double? = null): ListeningStatus {
        val value = seconds ?: 30.0
        requireDuration(value, signed = true)
        return control("skip", value)
    }

    /**
     * Seeks within the loaded item, preserving whether it is playing or paused. Clamped to the item's duration.
     * @param positionSeconds Absolute position from zero to 86400 seconds. Article seconds refer only to this device's rendered audio.
     */
    @AppFunction(isEnabled = false, isDescribedByKDoc = true)
    suspend fun seekListening(positionSeconds: Double): ListeningStatus {
        requireDuration(positionSeconds)
        return control("seek", positionSeconds)
    }

    /**
     * Changes playback speed for the loaded content kind. Podcast and article preferences are separate.
     * @param speed Speed multiplier from 0.5 to 3.0.
     */
    @AppFunction(isEnabled = false, isDescribedByKDoc = true)
    suspend fun setListeningSpeed(speed: Double): ListeningStatus = action {
        require(speed.isFinite() && speed in 0.5..3.0) { "Choose a speed between 0.5 and 3." }
        control("speed", speed)
    }

    /** Undoes the last assistant speed change within ten minutes, only if its account and resulting speed still match. */
    @AppFunction(isEnabled = false, isDescribedByKDoc = true)
    suspend fun undoListeningSpeed(): ListeningStatus = control("undo_speed")

    /**
     * Stops playback after a wall-clock interval; pausing or changing speed does not extend it. Requires a loaded item.
     * @param minutes Timer duration from one to 1440 minutes, rounded up to the next whole minute.
     */
    @AppFunction(isEnabled = false, isDescribedByKDoc = true)
    suspend fun setListeningSleepTimer(minutes: Double): ListeningStatus = action {
        require(minutes.isFinite() && minutes in 1.0..1440.0) { "Choose a timer from one minute to 24 hours." }
        control("sleep", minutes)
    }

    /** Cancels the sleep timer without resuming paused playback. */
    @AppFunction(isEnabled = false, isDescribedByKDoc = true)
    suspend fun cancelListeningSleepTimer(): ListeningStatus = control("cancel_sleep")

    /**
     * Plays a specific library item from its saved place; completed items restart from the beginning.
     * Waits for playback to start. If openMagpie is returned, ask the user to open it to finish starting playback; do not claim it has started.
     * @param itemId Unchanged account-scoped ID returned by findItems.
     */
    @AppFunction(isEnabled = false, isDescribedByKDoc = true)
    suspend fun playListeningItem(itemId: String): ListeningStart = start("play_item", Bundle().apply { putString("item_id", itemId) })

    /**
     * Continues the current account's last listening item, retaining a loaded player's newer position.
     * If openMagpie is returned, ask the user to open it to finish starting playback; do not claim it has started.
     */
    @AppFunction(isEnabled = false, isDescribedByKDoc = true)
    suspend fun continueListening(): ListeningStart = start("continue")

    /**
     * Plays the newest unfinished, undismissed item from Latest or a followed show.
     * If openMagpie is returned, ask the user to open it to finish starting playback; do not claim it has started.
     * @param showId Optional unchanged ID returned by listShows; omitted means Latest.
     */
    @AppFunction(isEnabled = false, isDescribedByKDoc = true)
    suspend fun playLatestListeningItem(showId: String? = null): ListeningStart = start("latest", Bundle().apply { putString("show_id", showId) })

    /**
     * Marks an item played/read, dismisses it from Latest, or marks it unplayed/unread.
     * Updates the signed-in account on every device without using AI. Repeat the same request after a connection failure to recover its result.
     * @param filing One of played, dismissed, or restored. Restored clears both played and dismissed state.
     * @param itemId Optional unchanged account-scoped ID from findItems; omitted uses the currently loaded item.
     * @param startNewChange Defaults to false, recovering an uncertain previous result. Set true only when the user explicitly requests a new change after checking a stopped or unconfirmed request.
     */
    @AppFunction(isEnabled = false, isDescribedByKDoc = true)
    suspend fun fileListeningItem(filing: String, itemId: String? = null, startNewChange: Boolean? = null): LibraryChange = action(timeoutMs = 90_000) {
        val action = when (filing) {
            "played" -> "mark_played"
            "dismissed" -> "dismiss"
            "restored" -> "restore"
            else -> throw AppFunctionInvalidArgumentException("Choose played, dismissed, or restored.")
        }
        changeLibrary(action, itemId, startNewChange == true)
    }

    /**
     * Undoes the account's most recent reversible library change, including filing or a voice-command subscription change.
     * Does not undo a local playback-speed change; use undoListeningSpeed for that.
     * Repeat after a connection failure to recover the same Undo result. Only announce a change when changed is true.
     * @param startNewChange Defaults to false. Set true only when the user explicitly requests a new Undo after checking a stopped or unconfirmed request; never automatically repeat a potentially completed Undo.
     */
    @AppFunction(isEnabled = false, isDescribedByKDoc = true)
    suspend fun undoLastLibraryAction(startNewChange: Boolean? = null): LibraryChange = action(timeoutMs = 90_000) { changeLibrary("undo", null, startNewChange == true) }

    private suspend fun changeLibrary(action: String, suppliedId: String?, startNewChange: Boolean): LibraryChange {
        val state = ready(waitForLibrary = false)
        fun episodeId(id: String): Int {
            val prefix = "${state.owner}:episode:"
            require(id.startsWith(prefix)) { "That item belongs to another account. Find it again." }
            return id.removePrefix(prefix).toIntOrNull()?.takeIf { it > 0 }
                ?: throw AppFunctionInvalidArgumentException("Choose a valid library item.")
        }
        suppliedId?.let(::episodeId)
        val media = connect()
        val token = java.util.UUID.randomUUID().toString()
        var acquired = false
        var safeToResume = true
        var operation: com.henrydashwood.magpie.voice.VoiceOperation? = null
        suspend fun send(name: String, args: Bundle): Bundle {
            checkAccount(state)
            val result = awaitResult(media.sendCustomCommand(SessionCommand(name, Bundle.EMPTY), args))
            checkAccount(state)
            if (result.resultCode != SessionResult.RESULT_SUCCESS) throw CancellationException("Listening changed")
            return result.extras
        }
        val host = com.henrydashwood.magpie.voice.PlaybackVoiceHost(library, PreviewStore(this),
            { library.state.value.items.firstOrNull { it.id == media.currentMediaItem?.mediaId } }, {}, ::send)
        fun checkHold() {
            checkAccount(state)
            if (!host.valid(token, state.revision)) throw CancellationException("Listening changed")
        }
        try {
            checkAccount(state)
            val id = if (action == "undo") null else suppliedId ?: library.actions.pendingCurrentItem(action)?.takeUnless { startNewChange }?.let { "${state.owner}:episode:$it" }
                ?: send(PlaybackService.AUTOMATION_CONTROL, Bundle().apply {
                putString("action", "status"); putString("owner", state.owner); putInt("revision", state.revision)
            }).getString("item_id") ?: throw AppFunctionInvalidArgumentException("Choose an item, or start listening first.")
            val response = library.actions.run(action, id?.let(::episodeId), useCurrent = suppliedId == null && action != "undo", startNewChange = startNewChange, before = { requestId ->
                host.begin(token, state.revision); acquired = true
                host.drain(token, requestId)
                checkHold()
            }, send = { requestId ->
                safeToResume = false
                val request = library.libraryAction(action, id?.let(::episodeId), requestId, state.revision)
                operation = request
                coroutineScope {
                    val result = async { request.response() }
                    val interrupted = launch {
                        com.henrydashwood.magpie.playback.PlaybackStatus.voiceToken.first { it != token }
                        result.cancel(CancellationException("Listening changed"))
                    }
                    try { result.await().also { operation = null } } finally { interrupted.cancel() }
                }
            }, reconcile = { receipt ->
                safeToResume = false
                checkHold(); host.reconcile(receipt, token, state.revision); checkHold()
                safeToResume = true
            })
            val item = response.episode?.let { row -> library.state.value.items.firstOrNull { it.episodeId == row.id } }?.let(::item)
            return LibraryChange(response.action != com.henrydashwood.magpie.voice.VoiceAction.Unknown, response.spokenResponse, item)
        } finally {
            withContext(NonCancellable) {
                withTimeoutOrNull(5_000) { operation?.let { runCatching { it.cancel() } } }
                if (acquired) withTimeoutOrNull(5_000) { runCatching { host.end(token, safeToResume) } }
            }
            media.release()
        }
    }

    private fun requireDuration(value: Double, signed: Boolean = false) {
        if (!value.isFinite() || value !in (if (signed) -86_400.0 else 0.0)..86_400.0)
            throw AppFunctionInvalidArgumentException("Choose a duration of up to 24 hours.")
    }

    private suspend fun control(name: String, value: Double? = null): ListeningStatus = action {
        val state = ready(waitForLibrary = false)
        status(request(state, name, Bundle().apply { value?.let { putDouble("value", it) } }))
    }

    private suspend fun start(name: String, arguments: Bundle = Bundle()): ListeningStart = action(timeoutMs = 150_000) {
        val state = ready()
        val snapshot = request(state, name, arguments)
        val status = status(snapshot)
        val open = if (snapshot.getBoolean("foreground_required")) {
            val id = checkNotNull(snapshot.getString("item_id"))
            val intent = com.henrydashwood.magpie.shortcuts.MagpieShortcuts.intent(this,
                com.henrydashwood.magpie.shortcuts.ShortcutRequest(com.henrydashwood.magpie.shortcuts.ShortcutAction.PlayItem,
                    owner = state.owner, itemId = id))
                .setData(android.net.Uri.Builder().scheme("magpie-automation").authority("play").appendPath(java.util.UUID.randomUUID().toString()).build())
            PendingIntent.getActivity(this, 0, intent, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_ONE_SHOT)
        } else null
        ListeningStart(status, open)
    }

    private suspend fun request(state: LibraryState, action: String, arguments: Bundle): Bundle {
        val media = connect()
        try {
            checkAccount(state)
            arguments.putString("action", action); arguments.putString("owner", state.owner); arguments.putInt("revision", state.revision)
            val result = awaitResult(media.sendCustomCommand(SessionCommand(PlaybackService.AUTOMATION_CONTROL, Bundle.EMPTY), arguments))
            checkAccount(state)
            val message = result.extras.getString("error") ?: "The listening request could not be completed."
            if (result.extras.getBoolean("cancelled")) throw CancellationException(message)
            when (result.resultCode) {
                SessionResult.RESULT_SUCCESS -> return result.extras
                SessionError.ERROR_PERMISSION_DENIED -> throw AppFunctionPermissionRequiredException(message)
                SessionError.ERROR_BAD_VALUE -> throw AppFunctionInvalidArgumentException(message)
                else -> throw AppFunctionAppUnknownException(message)
            }
        } finally { media.release() }
    }

    private fun status(snapshot: Bundle) = ListeningStatus(
        library.state.value.items.firstOrNull { it.id == snapshot.getString("item_id") }?.let(::item),
        snapshot.getBoolean("playing"), snapshot.getDouble("position"),
        if (snapshot.containsKey("remaining")) snapshot.getDouble("remaining") else null,
        snapshot.getDouble("speed"), if (snapshot.containsKey("sleep_end")) snapshot.getLong("sleep_end") else null,
    )

    private suspend fun awaitResult(future: com.google.common.util.concurrent.ListenableFuture<SessionResult>): SessionResult =
        suspendCancellableCoroutine { continuation ->
            continuation.invokeOnCancellation { future.cancel(false) }
            future.addListener({
                if (continuation.isActive) try { continuation.resume(future.get()) }
                catch (failure: Exception) { continuation.resumeWithException(failure.cause ?: failure) }
            }, mainExecutor)
        }

    private suspend fun connect(): MediaController = suspendCancellableCoroutine { continuation ->
        val future = MediaController.Builder(this, SessionToken(this, ComponentName(this, PlaybackService::class.java))).buildAsync()
        continuation.invokeOnCancellation { MediaController.releaseFuture(future) }
        future.addListener({
            try {
                val controller = future.get()
                if (continuation.isActive) continuation.resume(controller) else controller.release()
            } catch (failure: Exception) { if (continuation.isActive) continuation.resumeWithException(failure) }
        }, mainExecutor)
    }
}
