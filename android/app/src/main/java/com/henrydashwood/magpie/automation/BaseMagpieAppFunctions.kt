package com.henrydashwood.magpie.automation

import android.content.ComponentName
import android.os.SystemClock
import androidx.annotation.RequiresApi
import androidx.appfunctions.*
import androidx.media3.session.MediaController
import androidx.media3.session.SessionToken
import com.henrydashwood.magpie.MagpieApplication
import com.henrydashwood.magpie.data.*
import com.henrydashwood.magpie.playback.PlaybackService
import com.henrydashwood.magpie.playback.PlaybackStatus
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

@RequiresApi(36)
@AppFunctionServiceEntryPoint(serviceName = "MagpieAppFunctions", appFunctionXmlFileName = "magpie_app_functions")
@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
abstract class BaseMagpieAppFunctions : AppFunctionService() {
    private val library get() = (application as MagpieApplication).library

    private suspend fun ready(): LibraryState {
        val revision = library.state.value.revision
        val state = library.state.first { !it.loading }
        if (state.revision != revision) throw CancellationException("Account changed")
        if (!state.live || state.owner == null) throw AppFunctionPermissionRequiredException("Open Magpie and sign in first.")
        return state
    }
    private fun checkAccount(state: LibraryState) {
        if (library.state.value.revision != state.revision || library.state.value.owner != state.owner)
            throw CancellationException("Account changed")
    }
    private suspend fun <T> action(work: suspend () -> T): T = withContext(Dispatchers.Main.immediate) {
        try { withTimeout(30_000) { work() } }
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
    suspend fun getListeningStatus(): ListeningStatus = action {
        val state = ready()
        val media = connect()
        try {
            checkAccount(state)
            val current = library.state.value.items.firstOrNull { it.id == media.currentMediaItem?.mediaId }
            val remaining = media.duration.takeIf { it > 0 }?.let { (it - media.currentPosition).coerceAtLeast(0) / 1000.0 }
            val deadline = PlaybackStatus.sleepTimer.value.deadlineMs
            ListeningStatus(current?.let(::item), media.isPlaying, media.currentPosition.coerceAtLeast(0) / 1000.0,
                remaining, media.playbackParameters.speed.toDouble(), deadline?.let {
                    System.currentTimeMillis() + (it - SystemClock.elapsedRealtime()).coerceAtLeast(0)
                })
        } finally { media.release() }
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
