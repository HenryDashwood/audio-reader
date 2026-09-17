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
import kotlinx.coroutines.flow.combine
import com.henrydashwood.magpie.voice.*
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

/** One feed discovered at the requested website. */
@AppFunctionSerializable(isDescribedByKDoc = true)
data class PublicationFeedChoice(
    /** Opaque choice ID; pass it unchanged with the same website URL. */ val id: String,
    val title: String,
    /** The feed address, to distinguish choices with identical titles. */ val url: String,
)

/** A confirmed subscription, or choices requiring the user's selection before anything is followed. */
@AppFunctionSerializable(isDescribedByKDoc = true)
data class PublicationFollowResult(
    val message: String,
    /** Non-null only when the subscription is confirmed. */ val show: FollowedShow?,
    /** Ask the user to choose when non-empty, then repeat with that choice ID. */ val choices: List<PublicationFeedChoice>,
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

/** An action the user can open to navigate in Magpie. Creating it does not change playback or open a screen. */
@AppFunctionSerializable(isDescribedByKDoc = true)
data class MagpieDestination(
    val title: String,
    /** Immutable, one-use action. Ask the user to open it; do not announce that the screen is already open. */
    val openMagpie: PendingIntent,
)

/** Result of a written or dictated request. A handoff preserves the original request; do not submit it again. */
@AppFunctionSerializable(isDescribedByKDoc = true)
data class MagpieRequestResult(
    val message: String,
    /** Ask this question to the user and call runMagpieRequest with their answer when true. */
    val expectsReply: Boolean,
    val item: ListeningItem?,
    /** Ask the user to open this one-use action to review consent or finish the same request. */
    val openMagpie: PendingIntent?,
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

    /** Returns the signed-in account's newsletter address for receiving newsletters in Magpie. Requires no AI permission. */
    @AppFunction(isEnabled = false, isDescribedByKDoc = true)
    suspend fun getNewsletterAddress(): String = action {
        val state = ready(waitForLibrary = false)
        val address = library.newsletterAddress()
        checkAccount(state)
        address.address
    }

    /**
     * Finds and follows a podcast or publication feed at a website address, without AI.
     * When several feeds are found, ask the user to choose from the returned choices; nothing is followed yet.
     * @param url Website or feed address beginning with https or http.
     * @param choiceId Unchanged ID chosen by the user from this function's choices, or omit to discover feeds.
     */
    @AppFunction(isEnabled = false, isDescribedByKDoc = true)
    suspend fun followPublicationUrl(url: String, choiceId: String? = null): PublicationFollowResult = action {
        val state = ready()
        val result = library.followPublication(url, choiceId)
        checkAccount(state)
        val feed = result.feed
        PublicationFollowResult(if (feed == null) "Which feed would you like to follow?"
            else if (result.alreadyFollowed) "You already follow ${feed.title}." else "Following ${feed.title}.",
            feed?.let { FollowedShow(scopedShowId(state, it), it.title, it.articles) },
            result.choices.map { PublicationFeedChoice(it.id, it.title, it.url) })
    }

    /**
     * Runs a written or dictated Magpie request. Playback commands stay on device and library Undo uses the account without AI.
     * Other library requests require sign-in and existing AI consent.
     * Ask a returned question and pass the user's answer here when expectsReply is true. If openMagpie is returned, ask the user to open it;
     * it continues the original request. Never automatically resubmit an uncertain library change.
     * @param request The user's own request or clarification, from one to 2000 characters.
     */
    @AppFunction(isEnabled = true, isDescribedByKDoc = true)
    suspend fun runMagpieRequest(request: String): MagpieRequestResult = action(timeoutMs = 150_000) {
        val text = request.trim()
        require(text.isNotEmpty() && text.length <= 2_000) { "Please ask in a shorter sentence." }
        val command = LocalCommand.match(text)
        val state = if (command == null) ready() else library.state.value
        val account = "${state.revision}:${state.owner}:${state.live}"
        val context = library.voiceConversation
        context.activate(account)
        val token = java.util.UUID.randomUUID().toString()
        // Explicit player controls remain available while a library request is
        // waiting. The service invalidates that request's hold before applying
        // the control; a second library request must never steal the lease.
        val acquiredExecution = context.acquire(token)
        check(acquiredExecution || command != null && command !in setOf(LocalCommand.Undo, LocalCommand.EndConversation)) {
            "Magpie is already handling a request. Let it finish and try again."
        }
        fun handoff(message: String, recovery: Boolean = false): MagpieRequestResult {
            checkAccount(state)
            val pending = context.pending.takeIf { recovery }
            val nonce = library.voiceHandoffs.create(account, context.generation(), pending?.transcript ?: text, pending?.requestId)
            val open = destination(com.henrydashwood.magpie.shortcuts.ShortcutRequest(
                com.henrydashwood.magpie.shortcuts.ShortcutAction.RunRequest, owner = state.owner ?: "sample", handoffId = nonce), "Continue Magpie request")
            return MagpieRequestResult(message, false, null, open.openMagpie)
        }
        try {
            if (command != null) {
                val result = localRequest(command, state)
                context.userSaid(text); context.appSaid(result.message)
                return@action result
            }
            val allowed = try { withTimeoutOrNull(20_000) { library.aiConsent() } }
            catch (cancelled: CancellationException) { throw cancelled }
            catch (_: Exception) { null }
            checkAccount(state)
            if (allowed != true) return@action handoff(if (allowed == false)
                "Open Magpie to review AI data sharing and continue your request." else "Open Magpie to continue your request.")
            val media = connect()
            var acquired = false
            var safeToResume = true
            var operation: VoiceOperation? = null
            var preserveRequest = false
            var interrupted: Job? = null
            var started: ListeningStart? = null
            var requestCreated = false
            suspend fun send(name: String, args: Bundle): Bundle {
                checkAccount(state)
                val result = awaitResult(media.sendCustomCommand(SessionCommand(name, Bundle.EMPTY), args))
                checkAccount(state)
                if (result.resultCode != SessionResult.RESULT_SUCCESS) throw CancellationException("Listening changed")
                return result.extras
            }
            lateinit var host: PlaybackVoiceHost
            fun checkHold() {
                checkAccount(state)
                if (!host.valid(token, state.revision)) throw CancellationException("Listening changed")
            }
            host = PlaybackVoiceHost(library, PreviewStore(this),
                { library.state.value.items.firstOrNull { it.id == media.currentMediaItem?.mediaId } }, {}, ::send,
                startPlayback = { selected ->
                    checkHold()
                    val controls = com.henrydashwood.magpie.playback.PlaybackStatus.controlVersion.value
                    interrupted?.cancel(); interrupted = null
                    host.end(token, false); acquired = false
                    started = startInAccount(state, "play_item", Bundle().apply {
                        putString("item_id", selected.id); putInt("expected_controls", controls)
                    }, media)
                })
            try {
                host.begin(token, state.revision); acquired = true; checkHold()
                coroutineScope {
                    val caller = currentCoroutineContext().job
                    interrupted = launch {
                        combine(library.state, com.henrydashwood.magpie.playback.PlaybackStatus.voiceToken) { current, held ->
                            current.revision != state.revision || current.owner != state.owner || held != token
                        }.first { it }
                        caller.cancel(CancellationException("Listening changed"))
                    }
                    try {
                        val recovering = text.lowercase(java.util.Locale.ROOT).trimEnd('.', '?', '!') in
                            setOf("try again", "did that work", "what happened", "check that request")
                        val voiceRequest = context.request(text, playingEpisodeId = host.account().playingEpisodeId,
                            country = host.account().country, recover = recovering)
                        requestCreated = true
                        safeToResume = false
                        val response = withTimeoutOrNull(20_000) {
                            host.prepareRequest(voiceRequest, token); checkHold()
                            context.receipt ?: host.operation(voiceRequest, state.revision).also { operation = it }.response()
                                .also { context.confirmed(voiceRequest, account, it) }
                        }
                        if (response == null) {
                            preserveRequest = true
                            return@coroutineScope handoff("The result is not confirmed yet. Open Magpie to check the same request.", recovery = true)
                        }
                        operation = null
                        checkHold(); host.reconcile(response, token, state.revision); checkHold()
                        safeToResume = true
                        host.apply(response, token, state.revision)
                        checkAccount(state)
                        context.applied(voiceRequest, account, response.effects.map {
                            "${it.action.wire}: ${it.spokenResponse}" + (it.episode?.let { row -> " [episode_id=${row.id}]" } ?: "")
                        })
                        val playback = started
                        val message = if (playback?.openMagpie != null) "Open Magpie to finish starting playback." else response.spokenResponse
                        context.appSaid(message)
                        MagpieRequestResult(message, response.expectsReply, playback?.status?.item ?: response.episode?.let { row ->
                            library.state.value.items.firstOrNull { it.episodeId == row.id }?.let(::item)
                        }, playback?.openMagpie)
                    } finally { interrupted?.cancel() }
                }
            } catch (cancelled: CancellationException) { throw cancelled
            } catch (_: Exception) {
                preserveRequest = true
                handoff("That request could not finish. Open Magpie to check the same request.", recovery = requestCreated)
            } finally {
                withContext(NonCancellable) {
                    if (!preserveRequest) withTimeoutOrNull(5_000) { operation?.let { runCatching { it.cancel() } } }
                    if (acquired) withTimeoutOrNull(5_000) { runCatching { host.end(token, safeToResume) } }
                }
                media.release()
            }
        } finally { context.release(token) }
    }

    private suspend fun localRequest(command: LocalCommand, state: LibraryState): MagpieRequestResult {
        if (command == LocalCommand.EndConversation) {
            library.voiceConversation.clear()
            return MagpieRequestResult("Conversation ended.", false, null, null)
        }
        if (command == LocalCommand.Resume) {
            val result = startInAccount(state, "continue")
            return MagpieRequestResult(if (result.openMagpie != null) "Open Magpie to continue listening." else "Listening resumed.", false, result.status.item, result.openMagpie)
        }
        if (command == LocalCommand.Undo && library.speedUndo?.let {
            it.owner == state.owner && it.revision == state.revision && android.os.SystemClock.elapsedRealtime() < it.expiresAt
        } != true) {
            val result = changeLibrary("undo", null, false)
            return MagpieRequestResult(result.message, false, result.item, null)
        }
        val (name, value, message) = when (command) {
            LocalCommand.Pause -> Triple("pause", null, "Listening paused.")
            is LocalCommand.Seek -> Triple("skip", command.seconds, "Listening position updated.")
            is LocalCommand.Speed -> Triple("speed", command.rate.toDouble(), "Playback speed updated.")
            is LocalCommand.AdjustSpeed -> {
                val current = status(request(state, "status", Bundle())).speed
                Triple("speed", (current + command.delta).coerceIn(.5, 3.0), "Playback speed updated.")
            }
            is LocalCommand.Sleep -> Triple("sleep", command.minutes.toDouble(), "Sleep timer set for ${command.minutes} minutes.")
            LocalCommand.CancelSleep -> Triple("cancel_sleep", null, "Sleep timer off.")
            LocalCommand.Undo -> Triple("undo_speed", null, "Playback speed restored.")
            else -> error("Unsupported local command")
        }
        val result = status(request(state, name, Bundle().apply { value?.let { putDouble("value", it) } }))
        return MagpieRequestResult(message, false, result.item, null)
    }

    /**
     * Returns an action to open a Magpie screen without starting playback or the microphone.
     * Ask the user to open the returned action. Also available before sign-in.
     * @param destination One of latest, following, saved, nowPlaying, or shortcuts.
     */
    @AppFunction(isEnabled = true, isDescribedByKDoc = true)
    suspend fun openMagpieDestination(destination: String): MagpieDestination = action {
        val choice = when (destination) {
            "latest" -> com.henrydashwood.magpie.shortcuts.ShortcutAction.OpenLatest
            "following" -> com.henrydashwood.magpie.shortcuts.ShortcutAction.Following
            "saved" -> com.henrydashwood.magpie.shortcuts.ShortcutAction.Saved
            "nowPlaying" -> com.henrydashwood.magpie.shortcuts.ShortcutAction.Player
            "shortcuts" -> com.henrydashwood.magpie.shortcuts.ShortcutAction.Shortcuts
            else -> throw AppFunctionInvalidArgumentException("Choose latest, following, saved, nowPlaying, or shortcuts.")
        }
        val state = if (library.state.value.live) ready() else library.state.value
        destination(com.henrydashwood.magpie.shortcuts.ShortcutRequest(choice, owner = state.owner ?: "sample"), choice.label)
    }

    /**
     * Returns an action to open an item's details or article without playing it. Ask the user to open the returned action.
     * @param itemId Unchanged account-scoped ID from findItems.
     */
    @AppFunction(isEnabled = false, isDescribedByKDoc = true)
    suspend fun openListeningItem(itemId: String): MagpieDestination = action {
        val state = ready()
        val found = library.shortcutItem(itemId)
        checkAccount(state)
        destination(com.henrydashwood.magpie.shortcuts.ShortcutRequest(
            com.henrydashwood.magpie.shortcuts.ShortcutAction.ReadItem, owner = state.owner, itemId = found.id), found.title)
    }

    /**
     * Returns an action to open a followed show's list of items without playing it. Ask the user to open the returned action.
     * @param showId Unchanged account-scoped ID from listShows.
     */
    @AppFunction(isEnabled = false, isDescribedByKDoc = true)
    suspend fun openFollowedShow(showId: String): MagpieDestination = action {
        val state = ready()
        val feed = state.feeds.firstOrNull { scopedShowId(state, it) == showId }
            ?: throw AppFunctionElementNotFoundException("That show belongs to another account or is no longer followed. List shows again.")
        destination(com.henrydashwood.magpie.shortcuts.ShortcutRequest(
            com.henrydashwood.magpie.shortcuts.ShortcutAction.OpenFeed, owner = state.owner, feedId = feed.id), feed.title)
    }

    private fun destination(request: com.henrydashwood.magpie.shortcuts.ShortcutRequest, title: String): MagpieDestination {
        val intent = com.henrydashwood.magpie.shortcuts.MagpieShortcuts.intent(this, request)
            .setData(android.net.Uri.Builder().scheme("magpie-automation").authority("open").appendPath(java.util.UUID.randomUUID().toString()).build())
        return MagpieDestination(title, PendingIntent.getActivity(this, 0, intent, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_ONE_SHOT))
    }

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
                library.speedUndo = null
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
        startInAccount(state, name, arguments)
    }

    private suspend fun startInAccount(state: LibraryState, name: String, arguments: Bundle = Bundle(), media: MediaController? = null): ListeningStart {
        val snapshot = request(state, name, arguments, media)
        val status = status(snapshot)
        val open = if (snapshot.getBoolean("foreground_required")) {
            val id = checkNotNull(snapshot.getString("item_id"))
            val intent = com.henrydashwood.magpie.shortcuts.MagpieShortcuts.intent(this,
                com.henrydashwood.magpie.shortcuts.ShortcutRequest(com.henrydashwood.magpie.shortcuts.ShortcutAction.PlayItem,
                    owner = state.owner ?: "sample", itemId = id))
                .setData(android.net.Uri.Builder().scheme("magpie-automation").authority("play").appendPath(java.util.UUID.randomUUID().toString()).build())
            PendingIntent.getActivity(this, 0, intent, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_ONE_SHOT)
        } else null
        return ListeningStart(status, open)
    }

    private suspend fun request(state: LibraryState, action: String, arguments: Bundle, controller: MediaController? = null): Bundle {
        val media = controller ?: connect()
        try {
            checkAccount(state)
            arguments.putString("action", action); arguments.putString("owner", state.owner ?: "sample"); arguments.putInt("revision", state.revision)
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
        } finally { if (controller == null) media.release() }
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
