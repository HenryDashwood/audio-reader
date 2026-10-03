package com.henrydashwood.magpie.data

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import java.util.UUID
import kotlin.math.abs
import kotlin.math.roundToInt
import kotlin.math.roundToLong

/** How much episode audio the phone may keep, and what may arrive unasked. Matches iOS. */
data class DownloadSettings(
    /** Zero means no limit. */
    val limitBytes: Long = DEFAULT_LIMIT,
    val automatic: Boolean = true,
    val perShow: Int = 1,
    val wifiOnly: Boolean = true,
) {
    val limit: Long? get() = limitBytes.takeIf { it > 0 }

    companion object {
        const val GIGABYTE = 1_000_000_000L
        const val DEFAULT_LIMIT = 2 * GIGABYTE
        val limitOptions = listOf(1, 2, 5, 10).map { it * GIGABYTE } + 0L
        val perShowOptions = listOf(1, 2, 3)
        fun limitLabel(bytes: Long) = if (bytes > 0) formatBytes(bytes) else "No limit"
    }
}

enum class DownloadOrigin { Manual, Automatic }

sealed interface DownloadStatus {
    data class Queued(val waitingForWifi: Boolean) : DownloadStatus
    data class Downloading(val progress: Double) : DownloadStatus
    data object Downloaded : DownloadStatus
    data class Failed(val message: String) : DownloadStatus

    val active get() = this is Queued || this is Downloading
}

/** What is needed to list and play a download with no connection and no other cache. */
data class DownloadedEpisode(
    val id: String, val episodeId: Int?, val title: String, val source: String, val sourceId: String,
    val audioUrl: String, val durationSeconds: Int?, val imageUrl: String?, val publishedAt: String?, val description: String,
) {
    fun item() = LibraryItem(id = id, source = source, title = title, description = description, kind = ContentKind.Podcast,
        durationLabel = durationSeconds?.let { "${maxOf(1, (it / 60.0).roundToInt())} min" }.orEmpty(), text = "",
        episodeId = episodeId, sourceId = sourceId, audioUrl = audioUrl, durationSeconds = durationSeconds,
        imageUrl = imageUrl, publishedAt = publishedAt)

    companion object {
        fun from(item: LibraryItem) = item.audioUrl?.let { url ->
            DownloadedEpisode(item.id, item.episodeId, item.title, item.source, item.sourceId, url, item.durationSeconds,
                item.imageUrl, item.publishedAt, item.description)
        }
    }
}

data class DownloadRecord(
    val episode: DownloadedEpisode,
    val origin: DownloadOrigin,
    val status: DownloadStatus,
    /** The measured size once downloaded; an estimate until then. */
    val bytes: Long,
    val requestedAt: Long,
    /** When she finished it. Finished downloads are the first to go. */
    val playedAt: Long? = null,
    /** The system download manager's row, while it has one. */
    val transferId: Long? = null,
    val path: String? = null,
    val allowsCellular: Boolean = true,
) {
    val id get() = episode.id
    val statusLabel get() = when (status) {
        is DownloadStatus.Queued -> if (status.waitingForWifi) "Waiting for Wi-Fi" else "Waiting to download"
        is DownloadStatus.Downloading -> if (status.progress > 0) "Downloading ${(status.progress * 100).roundToInt()}%" else "Downloading"
        DownloadStatus.Downloaded -> "Downloaded"
        is DownloadStatus.Failed -> "Download failed"
    }
}

data class DownloadManifest(val owner: String? = null, val epoch: String = UUID.randomUUID().toString(),
    val records: List<DownloadRecord> = emptyList())

/** The rules about what to keep, separate from files and network. The same rules as iOS. */
object DownloadPolicy {
    /** 128 kbit/s, the common podcast bitrate; feeds rarely state a size worth trusting. */
    const val BYTES_PER_SECOND = 16_000L
    const val FALLBACK_BYTES = 50_000_000L
    /** Long enough to go back to the end of something she just finished. */
    const val PLAYED_RETENTION_MS = 24 * 60 * 60 * 1000L
    /** Left free however generous the limit. */
    const val FREE_SPACE_MARGIN = 500_000_000L

    fun estimate(episode: DownloadedEpisode) = episode.durationSeconds?.takeIf { it > 0 }?.let { it * BYTES_PER_SECOND } ?: FALLBACK_BYTES

    fun used(records: Collection<DownloadRecord>) = records.filter { it.status !is DownloadStatus.Failed }.sumOf { it.bytes }

    /** Finished first (oldest first), then automatic (oldest first). Never unheard manual or the player's item. */
    fun evictable(records: Collection<DownloadRecord>, protecting: String?): List<DownloadRecord> {
        val candidates = records.filter { it.id != protecting && it.status !is DownloadStatus.Failed }
        return candidates.filter { it.playedAt != null }.sortedBy { it.playedAt } +
            candidates.filter { it.playedAt == null && it.origin == DownloadOrigin.Automatic }.sortedBy { it.requestedAt }
    }

    fun evictions(adding: Long, records: Collection<DownloadRecord>, limit: Long?, protecting: String?, onlyPlayed: Boolean = false): List<String> {
        limit ?: return emptyList()
        var excess = used(records) + adding - limit
        val removed = mutableListOf<String>()
        for (record in evictable(records, protecting)) {
            if (excess <= 0 || (onlyPlayed && record.playedAt == null)) break
            removed += record.id
            excess -= record.bytes
        }
        return removed
    }

    fun overage(adding: Long, records: Collection<DownloadRecord>, limit: Long?, protecting: String?): Long {
        limit ?: return 0
        val freed = evictable(records, protecting).sumOf { it.bytes }
        return maxOf(0, used(records) - freed + adding - limit)
    }

    fun expired(records: Collection<DownloadRecord>, now: Long, protecting: String?) =
        records.filter { it.id != protecting && it.playedAt?.let { played -> now - played >= PLAYED_RETENTION_MS } == true }.map { it.id }

    data class AutomaticPlan(val start: List<DownloadedEpisode> = emptyList(), val remove: List<String> = emptyList())

    /** The newest unheard episodes of each followed show, from Latest. */
    fun automaticPlan(latest: List<LibraryItem>, records: Collection<DownloadRecord>, settings: DownloadSettings,
        protecting: String?, freeSpace: Long?, now: Long): AutomaticPlan {
        val perShow = mutableMapOf<String, Int>()
        val wanted = mutableListOf<DownloadedEpisode>()
        if (settings.automatic) for (item in latest) {
            if (item.audioUrl == null || item.completed || item.dismissed) continue
            val count = perShow[item.sourceId] ?: 0
            if (count >= settings.perShow) continue
            perShow[item.sourceId] = count + 1
            DownloadedEpisode.from(item)?.let(wanted::add)
        }
        val wantedIds = wanted.map { it.id }.toSet()
        val remove = records.filter { it.origin == DownloadOrigin.Automatic && it.playedAt == null && it.id !in wantedIds && it.id != protecting }
            .map { it.id }.toMutableList()
        var remaining = records.filter { it.id !in remove }
        var space = freeSpace
        val start = mutableListOf<DownloadedEpisode>()
        for (episode in wanted) {
            val existing = records.firstOrNull { it.id == episode.id }
            // A failed automatic download is tried again; anything else already here is left alone.
            if (existing != null && !(existing.origin == DownloadOrigin.Automatic && existing.status is DownloadStatus.Failed)) continue
            val bytes = estimate(episode)
            if (space != null && space - bytes < FREE_SPACE_MARGIN) break
            val evict = evictions(bytes, remaining, settings.limit, protecting, onlyPlayed = true)
            val after = remaining.filter { it.id !in evict }
            val limit = settings.limit
            if (limit != null && used(after) + bytes > limit) break
            remove += evict
            remaining = after + DownloadRecord(episode, DownloadOrigin.Automatic, DownloadStatus.Queued(false), bytes, now)
            space = space?.minus(bytes)
            start += episode
        }
        return AutomaticPlan(start, remove)
    }
}

fun formatBytes(bytes: Long): String {
    val megabytes = bytes / 1_000_000.0
    return if (megabytes < 1000) "${megabytes.roundToLong().coerceAtLeast(if (bytes > 0) 1 else 0)} MB"
    else "${"%.1f".format(java.util.Locale.ROOT, megabytes / 1000).removeSuffix(".0")} GB"
}

/** "60 megabytes" rather than "60 MB", which a synthesiser reads as letters. `adjective`: "a 2 gigabyte limit". */
fun spokenBytes(bytes: Long, adjective: Boolean = false): String {
    val megabytes = bytes / 1_000_000.0
    if (megabytes < 1000) {
        val rounded = if (megabytes < 10) maxOf(1, megabytes.roundToInt()) else (megabytes / 10).roundToInt() * 10
        return "$rounded megabyte${if (rounded == 1 || adjective) "" else "s"}"
    }
    val gigabytes = (megabytes / 100).roundToInt() / 10.0
    val text = if (gigabytes % 1.0 == 0.0) gigabytes.toInt().toString() else gigabytes.toString()
    return "$text gigabyte${if (gigabytes == 1.0 || adjective) "" else "s"}"
}

/** A download she asked for that needs a yes: over the limit, or on mobile data. */
data class DownloadConfirmation(val episodes: List<DownloadedEpisode>, val estimatedBytes: Long, val limitBytes: Long?,
    val overLimitBytes: Long, val usesMobileData: Boolean, val id: String = UUID.randomUUID().toString()) {
    private val subject get() = if (episodes.size == 1) "This episode" else "These ${episodes.size} episodes"
    val title get() = if (overLimitBytes > 0) "Over your download limit" else "Download using mobile data?"
    val message get() = buildList {
        if (overLimitBytes > 0 && limitBytes != null) add("$subject will use about ${formatBytes(overLimitBytes)} more than your ${formatBytes(limitBytes)} download limit.")
        else add("$subject will use about ${formatBytes(estimatedBytes)}.")
        if (usesMobileData) add("You are not on Wi-Fi.")
    }.joinToString(" ")
    val spokenQuestion get() = buildList {
        if (overLimitBytes > 0 && limitBytes != null) add("That will use about ${spokenBytes(overLimitBytes)} more than your ${spokenBytes(limitBytes, adjective = true)} download limit.")
        add(if (usesMobileData) "You are not on Wi-Fi. Shall I download it now using mobile data, or wait for Wi-Fi?" else "Shall I download it anyway?")
    }.joinToString(" ")
}

sealed interface DownloadDecision {
    data class Started(val episodes: List<DownloadedEpisode>) : DownloadDecision
    data class NothingToDo(val message: String) : DownloadDecision
    data class Refused(val message: String) : DownloadDecision
    data class NeedsConfirmation(val confirmation: DownloadConfirmation) : DownloadDecision
}

data class DownloadTransferRequest(val url: String, val title: String, val fileName: String, val allowsCellular: Boolean, val visible: Boolean)

sealed interface TransferStatus {
    data class Pending(val waitingForWifi: Boolean) : TransferStatus
    data class Running(val progress: Double) : TransferStatus
    data class Succeeded(val path: String, val bytes: Long, val mediaType: String?) : TransferStatus
    data class Failed(val message: String) : TransferStatus
    /** The system no longer has the row, for example after the user cleared its downloads. */
    data object Missing : TransferStatus
}

/** The system's download manager, or a fake in tests. */
interface DownloadTransport {
    fun start(request: DownloadTransferRequest): Long
    /** Removes the row and any partial or finished file. */
    fun remove(ids: Collection<Long>)
    fun query(ids: Collection<Long>): Map<Long, TransferStatus>
    fun deleteFile(path: String)
    fun fileExists(path: String): Boolean
    fun freeSpace(): Long?
}

interface DownloadManifestStore {
    fun load(): DownloadManifest
    fun save(manifest: DownloadManifest)
}

interface DownloadSettingsStore {
    fun load(): DownloadSettings
    fun save(settings: DownloadSettings)
}

/**
 * Episode audio kept on the phone so it plays with no connection. Manual downloads stay until she has
 * finished them; automatic ones follow Latest within her storage limit. Everything goes on sign-out.
 * All methods run on the main thread.
 */
class EpisodeDownloads(
    private val transport: DownloadTransport,
    private val manifestStore: DownloadManifestStore,
    private val settingsStore: DownloadSettingsStore,
    private val scope: CoroutineScope,
    private val onMobileData: () -> Boolean,
    private val protecting: () -> String? = { null },
    private val now: () -> Long = System::currentTimeMillis,
    private val pollMs: Long = 1_500,
) {
    private var manifest = manifestStore.load()
    private val mutableRecords = MutableStateFlow(manifest.records.associateBy { it.id })
    val records: StateFlow<Map<String, DownloadRecord>> = mutableRecords.asStateFlow()
    private val mutableSettings = MutableStateFlow(settingsStore.load())
    val settings: StateFlow<DownloadSettings> = mutableSettings.asStateFlow()
    private val mutableAnnouncements = MutableSharedFlow<String>(extraBufferCapacity = 8)
    /** Said to her when one of her own downloads finishes or fails. */
    val announcements: SharedFlow<String> = mutableAnnouncements.asSharedFlow()
    private var polling: Job? = null
    private var latest: List<LibraryItem> = emptyList()
    private var pendingVoice: Pair<DownloadConfirmation, Long>? = null

    val usedBytes get() = DownloadPolicy.used(records.value.values)
    val sorted get() = records.value.values.sortedWith(compareByDescending<DownloadRecord> { it.status.active }.thenByDescending { it.requestedAt })

    fun record(id: String) = records.value[id]

    /** The downloaded audio, when it has all arrived. */
    fun localPath(item: LibraryItem): String? = records.value[item.id]?.takeIf { it.status == DownloadStatus.Downloaded }
        ?.path?.takeIf(transport::fileExists)

    fun request(items: List<LibraryItem>): DownloadDecision {
        val audio = items.mapNotNull(DownloadedEpisode::from)
        if (audio.isEmpty()) return DownloadDecision.NothingToDo("Only podcast episodes can be downloaded. Articles are kept on your phone once loaded.")
        val wanted = mutableListOf<DownloadedEpisode>()
        for (episode in audio) {
            val existing = records.value[episode.id]
            // Already here or on its way: asking for it makes it hers, so it is no longer removed to make room.
            if (existing == null || existing.status is DownloadStatus.Failed) wanted += episode else promote(episode.id)
        }
        if (wanted.isEmpty()) {
            val state = if (audio.any { records.value[it.id]?.status?.active == true }) "already downloading" else "already downloaded"
            return DownloadDecision.NothingToDo(if (audio.size == 1) "${audio[0].title} is $state." else "Those episodes are $state.")
        }
        val bytes = wanted.sumOf(DownloadPolicy::estimate)
        transport.freeSpace()?.let { space ->
            if (space - bytes < DownloadPolicy.FREE_SPACE_MARGIN) return DownloadDecision.Refused(
                "There is not enough space on this phone. ${if (wanted.size == 1) "This episode needs" else "These episodes need"} about ${formatBytes(bytes)}. Remove some downloads or other things from the phone, then try again.")
        }
        val settings = settings.value
        val overage = DownloadPolicy.overage(bytes, records.value.values, settings.limit, protecting())
        val mobile = settings.wifiOnly && onMobileData()
        if (overage > 0 || mobile) return DownloadDecision.NeedsConfirmation(
            DownloadConfirmation(wanted, bytes, settings.limit, overage, mobile))
        enqueue(wanted, DownloadOrigin.Manual, allowsCellular = true)
        return DownloadDecision.Started(wanted)
    }

    fun confirm(confirmation: DownloadConfirmation, waitForWifi: Boolean) {
        if (pendingVoice?.first?.id == confirmation.id) pendingVoice = null
        enqueue(confirmation.episodes, DownloadOrigin.Manual, allowsCellular = !waitForWifi)
    }

    /** A confirmation asked out loud, waiting on her next answer for two minutes. */
    fun awaitVoiceAnswer(confirmation: DownloadConfirmation) { pendingVoice = confirmation to now() }
    fun takeVoiceQuestion(): DownloadConfirmation? = pendingVoice?.takeIf { now() - it.second < 120_000 }?.first.also { pendingVoice = null }

    fun remove(id: String) {
        removeQuietly(id)
        persist()
    }

    fun removeAll() {
        records.value.keys.toList().forEach(::removeQuietly)
        persist()
    }

    /** Sign-out or a server change: nothing here belongs to whoever is next. */
    fun clear(owner: String? = null) {
        transport.remove(records.value.values.mapNotNull { it.transferId })
        records.value.values.mapNotNull { it.path }.forEach(transport::deleteFile)
        manifest = DownloadManifest(owner = owner)
        mutableRecords.value = emptyMap()
        latest = emptyList()
        pendingVoice = null
        persist()
    }

    fun updateSettings(next: DownloadSettings) {
        if (next == settings.value) return
        settingsStore.save(next)
        mutableSettings.value = next
        enforceLimit()
        planAutomatic()
    }

    /**
     * Follows the account library: switching account clears everything, finished episodes are marked,
     * and Latest decides the automatic downloads. No request of its own.
     */
    fun libraryChanged(state: LibraryState) {
        if (!state.live) {
            if (records.value.isNotEmpty() || manifest.owner != null) clear()
            return
        }
        val owner = state.owner ?: return
        if (manifest.owner != owner) {
            if (manifest.owner != null || records.value.isNotEmpty()) clear(owner)
            else { manifest = manifest.copy(owner = owner); persist() }
        }
        val byId = state.items.associateBy { it.id }
        var changed = false
        for (record in records.value.values) {
            val item = byId[record.id] ?: continue
            if (item.completed && record.playedAt == null) { update(record.id) { it.copy(playedAt = now()) }; changed = true }
            else if (!item.completed && record.playedAt != null) { update(record.id) { it.copy(playedAt = null) }; changed = true }
        }
        if (changed) persist()
        removeExpired()
        if (!state.loading) {
            latest = state.latestIds.mapNotNull(byId::get)
            planAutomatic()
        }
        resume()
    }

    fun markPlayed(id: String) {
        if (records.value[id]?.playedAt != null || id !in records.value) return
        update(id) { it.copy(playedAt = now()) }; persist()
    }

    fun removeExpired() {
        val expired = DownloadPolicy.expired(records.value.values, now(), protecting())
        expired.forEach(::removeQuietly)
        if (expired.isNotEmpty()) persist()
    }

    fun enforceLimit() {
        val evict = DownloadPolicy.evictions(0, records.value.values, settings.value.limit, protecting())
        evict.forEach(::removeQuietly)
        if (evict.isNotEmpty()) persist()
    }

    /** Polls the system while anything is under way. Safe to call repeatedly. */
    fun resume() {
        if (polling?.isActive == true || records.value.values.none { it.status.active }) return
        polling = scope.launch {
            while (true) {
                try { sync() }
                catch (cancelled: CancellationException) { throw cancelled }
                catch (_: Exception) { /* The next pass tries again. */ }
                if (records.value.values.none { it.status.active }) break
                delay(pollMs)
            }
        }
    }

    /** One pass over the system's rows. Public for tests. */
    fun sync() {
        val active = records.value.values.filter { it.status.active }
        if (active.isEmpty()) return
        val statuses = transport.query(active.mapNotNull { it.transferId })
        var changed = false
        for (record in active) {
            val status = record.transferId?.let(statuses::get) ?: TransferStatus.Missing
            when (status) {
                is TransferStatus.Pending -> if (record.status != DownloadStatus.Queued(status.waitingForWifi)) {
                    update(record.id) { it.copy(status = DownloadStatus.Queued(status.waitingForWifi)) }; changed = true
                }
                is TransferStatus.Running -> {
                    val previous = (record.status as? DownloadStatus.Downloading)?.progress
                    // Whole steps of a few percent: every row on screen observes this.
                    if (previous == null || abs(previous - status.progress) >= .05) {
                        update(record.id) { it.copy(status = DownloadStatus.Downloading(status.progress)) }
                    }
                }
                is TransferStatus.Succeeded -> {
                    changed = true
                    if (status.mediaType?.startsWith("text/") == true) {
                        transport.remove(listOfNotNull(record.transferId))
                        fail(record, "The podcast’s server sent a web page instead of audio.")
                    } else {
                        update(record.id) { it.copy(status = DownloadStatus.Downloaded, path = status.path,
                            bytes = status.bytes.takeIf { bytes -> bytes > 0 } ?: it.bytes) }
                        if (record.origin == DownloadOrigin.Manual) mutableAnnouncements.tryEmit("Downloaded: ${record.episode.title}")
                    }
                }
                is TransferStatus.Failed -> { changed = true; transport.remove(listOfNotNull(record.transferId)); fail(record, status.message) }
                TransferStatus.Missing -> {
                    // Gone from the system without finishing: start again with the same rules.
                    changed = true
                    start(record.episode, record.origin, record.allowsCellular)
                }
            }
        }
        if (changed) persist()
    }

    private fun fail(record: DownloadRecord, message: String) {
        update(record.id) { it.copy(status = DownloadStatus.Failed(message), transferId = null) }
        if (record.origin == DownloadOrigin.Manual) mutableAnnouncements.tryEmit("Download failed: ${record.episode.title}")
    }

    private fun planAutomatic() {
        val plan = DownloadPolicy.automaticPlan(latest, records.value.values, settings.value, protecting(), transport.freeSpace(), now())
        plan.remove.forEach(::removeQuietly)
        if (plan.start.isNotEmpty()) enqueue(plan.start, DownloadOrigin.Automatic, allowsCellular = !settings.value.wifiOnly)
        else if (plan.remove.isNotEmpty()) persist()
    }

    private fun enqueue(episodes: List<DownloadedEpisode>, origin: DownloadOrigin, allowsCellular: Boolean) {
        for (episode in episodes) {
            if (origin == DownloadOrigin.Manual) {
                DownloadPolicy.evictions(DownloadPolicy.estimate(episode), records.value.values.filter { it.id != episode.id },
                    settings.value.limit, protecting()).forEach(::removeQuietly)
            }
            records.value[episode.id]?.transferId?.let { transport.remove(listOf(it)) }
            start(episode, origin, allowsCellular)
        }
        persist()
        resume()
    }

    private fun start(episode: DownloadedEpisode, origin: DownloadOrigin, allowsCellular: Boolean) {
        val extension = Regex("\\.(mp3|m4a|aac|mp4|m4b|wav|ogg|opus)$", RegexOption.IGNORE_CASE)
            .find(episode.audioUrl.substringBefore('?').substringBefore('#'))?.groupValues?.get(1)?.lowercase() ?: "mp3"
        val name = "episode-${episode.id.filter { it.isLetterOrDigit() }}-${manifest.epoch.take(8)}.$extension"
        val transferId = try {
            transport.start(DownloadTransferRequest(episode.audioUrl, episode.title, name, allowsCellular, origin == DownloadOrigin.Manual))
        } catch (cancelled: CancellationException) { throw cancelled }
        catch (_: Exception) { null }
        mutableRecords.value = records.value + (episode.id to DownloadRecord(episode, origin,
            if (transferId == null) DownloadStatus.Failed("The episode could not be downloaded.")
            else DownloadStatus.Queued(!allowsCellular && onMobileData()),
            DownloadPolicy.estimate(episode), now(), transferId = transferId, allowsCellular = allowsCellular))
    }

    private fun promote(id: String) {
        if (records.value[id]?.origin != DownloadOrigin.Automatic) return
        update(id) { it.copy(origin = DownloadOrigin.Manual) }; persist()
    }

    private fun removeQuietly(id: String) {
        val record = records.value[id] ?: return
        record.transferId?.takeIf { record.status.active }?.let { transport.remove(listOf(it)) }
        record.path?.let(transport::deleteFile)
        mutableRecords.value = records.value - id
    }

    private fun update(id: String, change: (DownloadRecord) -> DownloadRecord) {
        val record = records.value[id] ?: return
        mutableRecords.value = records.value + (id to change(record))
    }

    private fun persist() {
        manifest = manifest.copy(records = records.value.values.toList())
        try { manifestStore.save(manifest) } catch (_: Exception) { /* Kept in memory; the next change tries again. */ }
    }
}
