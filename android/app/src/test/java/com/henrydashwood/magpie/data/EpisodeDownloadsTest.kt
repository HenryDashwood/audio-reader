package com.henrydashwood.magpie.data

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import org.junit.After
import org.junit.Assert.*
import org.junit.Test

class EpisodeDownloadsTest {
    private fun podcast(id: Int, minutes: Int = 60, show: String = "show", completed: Boolean = false, dismissed: Boolean = false) =
        LibraryItem("episode-$id", "Show $show", "Episode $id", "", ContentKind.Podcast, "", "", episodeId = id, sourceId = show,
            audioUrl = "https://example.invalid/$id.mp3", durationSeconds = minutes * 60, completed = completed, dismissed = dismissed)
    private val hour = DownloadPolicy.estimate(checkNotNull(DownloadedEpisode.from(podcast(0))))

    private fun record(id: Int, origin: DownloadOrigin, playedAt: Long? = null, requestedAt: Long = 0, bytes: Long = hour) =
        DownloadRecord(checkNotNull(DownloadedEpisode.from(podcast(id))), origin, DownloadStatus.Downloaded, bytes, requestedAt, playedAt,
            path = "/files/$id.mp3")

    // Policy

    @Test fun estimatesFromDurationOrFallsBack() {
        assertEquals(57_600_000L, hour)
        assertEquals(DownloadPolicy.FALLBACK_BYTES, DownloadPolicy.estimate(checkNotNull(DownloadedEpisode.from(podcast(1).copy(durationSeconds = null)))))
    }

    @Test fun finishedThenAutomaticAreRemovedFirstAndManualNever() {
        val records = listOf(record(1, DownloadOrigin.Manual), record(2, DownloadOrigin.Automatic, requestedAt = 20),
            record(3, DownloadOrigin.Automatic, requestedAt = 10), record(4, DownloadOrigin.Manual, playedAt = 5))
        assertEquals(listOf("episode-4", "episode-3", "episode-2"), DownloadPolicy.evictable(records, null).map { it.id })
        assertEquals(listOf("episode-3", "episode-2"), DownloadPolicy.evictable(records, "episode-4").map { it.id })
    }

    @Test fun overageCountsOnlyWhatCannotBeRemoved() {
        val records = listOf(record(1, DownloadOrigin.Manual), record(2, DownloadOrigin.Automatic))
        assertEquals(0L, DownloadPolicy.overage(hour, records, 2 * hour, null))
        assertEquals(hour, DownloadPolicy.overage(2 * hour, records, 2 * hour, null))
        assertEquals(0L, DownloadPolicy.overage(9 * hour, records, null, null))
        assertEquals(listOf("episode-2"), DownloadPolicy.evictions(hour, records, 2 * hour, null))
    }

    @Test fun automaticKeepsTheNewestOfEachShowWithinTheLimit() {
        val latest = listOf(podcast(10, show = "a"), podcast(11, show = "a"), podcast(20, show = "b"),
            podcast(21, show = "b", completed = true), podcast(30, show = "c"))
        val plan = DownloadPolicy.automaticPlan(latest, emptyList(), DownloadSettings(limitBytes = 2 * hour), null, null, 0)
        assertEquals(listOf("episode-10", "episode-20"), plan.start.map { it.id })
        assertTrue(plan.remove.isEmpty())
    }

    @Test fun automaticDropsWhatLeftLatestButNotManualOrPlaying() {
        val records = listOf(record(1, DownloadOrigin.Automatic), record(2, DownloadOrigin.Manual), record(3, DownloadOrigin.Automatic))
        val plan = DownloadPolicy.automaticPlan(listOf(podcast(4)), records, DownloadSettings(), "episode-3", null, 0)
        assertEquals(listOf("episode-1"), plan.remove)
        assertEquals(listOf("episode-4"), plan.start.map { it.id })
    }

    @Test fun automaticMakesRoomOnlyFromFinishedEpisodes() {
        val records = listOf(record(1, DownloadOrigin.Manual, playedAt = 1), record(2, DownloadOrigin.Manual))
        val plan = DownloadPolicy.automaticPlan(listOf(podcast(5), podcast(6, show = "other")), records,
            DownloadSettings(limitBytes = 2 * hour), null, null, 0)
        assertEquals(listOf("episode-5"), plan.start.map { it.id })
        assertEquals(listOf("episode-1"), plan.remove)
    }

    @Test fun automaticOffRemovesUnheardAutomaticDownloadsAndLeavesSpaceOnThePhone() {
        val off = DownloadPolicy.automaticPlan(listOf(podcast(1)), listOf(record(1, DownloadOrigin.Automatic), record(2, DownloadOrigin.Manual)),
            DownloadSettings(automatic = false), null, null, 0)
        assertTrue(off.start.isEmpty())
        assertEquals(listOf("episode-1"), off.remove)
        val full = DownloadPolicy.automaticPlan(listOf(podcast(1)), emptyList(), DownloadSettings(), null, DownloadPolicy.FREE_SPACE_MARGIN + hour / 2, 0)
        assertTrue(full.start.isEmpty())
    }

    @Test fun finishedDownloadsExpireAfterADay() {
        val now = 10 * DownloadPolicy.PLAYED_RETENTION_MS
        val records = listOf(record(1, DownloadOrigin.Manual, playedAt = now - DownloadPolicy.PLAYED_RETENTION_MS - 1),
            record(2, DownloadOrigin.Manual, playedAt = now - 1000), record(3, DownloadOrigin.Manual))
        assertEquals(listOf("episode-1"), DownloadPolicy.expired(records, now, null))
        assertTrue(DownloadPolicy.expired(records, now, "episode-1").isEmpty())
    }

    @Test fun sizesAreWrittenAndSpoken() {
        assertEquals("58 MB", formatBytes(57_600_000))
        assertEquals("2 GB", formatBytes(2_000_000_000))
        assertEquals("1.5 GB", formatBytes(1_500_000_000))
        assertEquals("60 megabytes", spokenBytes(57_600_000))
        assertEquals("2 gigabytes", spokenBytes(2_000_000_000))
        assertEquals("2 gigabyte", spokenBytes(2_000_000_000, adjective = true))
        assertEquals("1 gigabyte", spokenBytes(1_000_000_000))
    }

    // Controller

    private class Transport : DownloadTransport {
        var next = 100L
        val started = mutableListOf<Pair<Long, DownloadTransferRequest>>()
        val removed = mutableListOf<Long>()
        val deleted = mutableListOf<String>()
        val statuses = mutableMapOf<Long, TransferStatus>()
        var free: Long? = 100_000_000_000
        override fun start(request: DownloadTransferRequest) = next++.also { started += it to request }
        override fun remove(ids: Collection<Long>) { removed += ids }
        // As the system does: a Wi-Fi-only download on mobile data waits for Wi-Fi.
        override fun query(ids: Collection<Long>) = ids.associateWith { id ->
            statuses[id] ?: TransferStatus.Pending(started.firstOrNull { it.first == id }?.second?.allowsCellular == false)
        }
        override fun deleteFile(path: String) { deleted += path }
        override fun fileExists(path: String) = path !in deleted
        override fun freeSpace() = free
        fun idFor(episode: Int) = started.last { it.second.title == "Episode $episode" }.first
    }
    private class Manifests : DownloadManifestStore {
        var saved = DownloadManifest()
        override fun load() = saved
        override fun save(manifest: DownloadManifest) { saved = manifest }
    }
    private class Settings(var value: DownloadSettings = DownloadSettings()) : DownloadSettingsStore {
        override fun load() = value
        override fun save(settings: DownloadSettings) { value = settings }
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
    @After fun stop() = scope.cancel()
    private val transport = Transport()
    private val manifests = Manifests()
    private var mobile = false
    private var now = 1_000_000L
    private fun downloads(settings: DownloadSettings = DownloadSettings()) =
        EpisodeDownloads(transport, manifests, Settings(settings), scope, { mobile }, now = { now }, pollMs = 60_000)
    private fun account(owner: String, latest: List<LibraryItem> = emptyList(), items: List<LibraryItem> = latest) =
        LibraryState(live = true, owner = owner, items = items, latestIds = latest.map { it.id })

    @Test fun aDownloadStartsArrivesAndSurvivesRelaunch() {
        val downloads = downloads()
        downloads.libraryChanged(account("alice"))
        assertEquals(DownloadDecision.Started::class, downloads.request(listOf(podcast(1)))::class)
        val (id, request) = transport.started.single()
        assertTrue(request.allowsCellular)
        assertTrue(request.visible)
        assertNull(downloads.localPath(podcast(1)))
        transport.statuses[id] = TransferStatus.Running(.5)
        downloads.sync()
        assertEquals("Downloading 50%", downloads.record("episode-1")?.statusLabel)
        transport.statuses[id] = TransferStatus.Succeeded("/files/1.mp3", 4321, "audio/mpeg")
        downloads.sync()
        assertEquals("/files/1.mp3", downloads.localPath(podcast(1)))
        assertEquals(4321L, downloads.record("episode-1")?.bytes)
        assertEquals("/files/1.mp3", downloads().localPath(podcast(1)))
    }

    @Test fun goingOverTheLimitNeedsAYesAndThenMakesRoom() {
        val downloads = downloads(DownloadSettings(limitBytes = 2 * hour))
        downloads.libraryChanged(account("alice"))
        downloads.request(listOf(podcast(1)))
        transport.statuses[transport.idFor(1)] = TransferStatus.Succeeded("/files/1.mp3", hour, "audio/mpeg")
        // Latest brings an automatic hour, filling the limit.
        downloads.libraryChanged(account("alice", listOf(podcast(2, show = "other"))))
        transport.statuses[transport.idFor(2)] = TransferStatus.Succeeded("/files/2.mp3", hour, "audio/mpeg")
        downloads.sync()
        assertEquals(DownloadOrigin.Automatic, downloads.record("episode-2")?.origin)
        assertFalse(transport.started.last { it.second.title == "Episode 2" }.second.visible)

        // A third hour fits by removing the automatic one: no question.
        assertTrue(downloads.request(listOf(podcast(3))) is DownloadDecision.Started)
        assertNull(downloads.record("episode-2"))
        val decision = downloads.request(listOf(podcast(4))) as DownloadDecision.NeedsConfirmation
        assertEquals(hour, decision.confirmation.overLimitBytes)
        assertTrue(decision.confirmation.message.contains("about 58 MB more than your 115 MB download limit"))
        assertEquals("That will use about 60 megabytes more than your 120 megabyte download limit. Shall I download it anyway?",
            decision.confirmation.spokenQuestion)
        downloads.confirm(decision.confirmation, waitForWifi = false)
        assertNotNull(downloads.record("episode-4"))
        assertNotNull(downloads.record("episode-1"))
        assertNotNull(downloads.record("episode-3"))
    }

    @Test fun mobileDataAsksAndCanWaitForWifi() {
        mobile = true
        val downloads = downloads()
        downloads.libraryChanged(account("alice"))
        val decision = downloads.request(listOf(podcast(1))) as DownloadDecision.NeedsConfirmation
        assertTrue(decision.confirmation.usesMobileData)
        downloads.confirm(decision.confirmation, waitForWifi = true)
        assertFalse(transport.started.last().second.allowsCellular)
        assertEquals(DownloadStatus.Queued(true), downloads.record("episode-1")?.status)
    }

    @Test fun mobileDataIsFineWhenWifiOnlyIsOffAndAFullPhoneRefuses() {
        mobile = true
        assertTrue(downloads(DownloadSettings(wifiOnly = false)).request(listOf(podcast(1))) is DownloadDecision.Started)
        transport.free = DownloadPolicy.FREE_SPACE_MARGIN
        val refused = downloads().request(listOf(podcast(2))) as DownloadDecision.Refused
        assertTrue(refused.message.contains("not enough space"))
    }

    @Test fun articlesAndDuplicatesAreNotDownloaded() {
        val downloads = downloads()
        val article = LibraryItem("a", "Paper", "Article", "", ContentKind.Article, "", "text")
        assertTrue(downloads.request(listOf(article)) is DownloadDecision.NothingToDo)
        downloads.request(listOf(podcast(1)))
        val again = downloads.request(listOf(podcast(1))) as DownloadDecision.NothingToDo
        assertEquals("Episode 1 is already downloading.", again.message)
        assertEquals(1, transport.started.size)
    }

    @Test fun askingForAnAutomaticDownloadMakesItManual() {
        val downloads = downloads()
        downloads.libraryChanged(account("alice", listOf(podcast(1))))
        assertEquals(DownloadOrigin.Automatic, downloads.record("episode-1")?.origin)
        assertFalse(transport.started.single().second.allowsCellular)
        downloads.request(listOf(podcast(1)))
        assertEquals(DownloadOrigin.Manual, downloads.record("episode-1")?.origin)
        downloads.libraryChanged(account("alice", emptyList(), listOf(podcast(1))))
        assertNotNull(downloads.record("episode-1"))
    }

    @Test fun finishingMarksAndExpiresAndUnplayingKeeps() {
        val downloads = downloads()
        downloads.libraryChanged(account("alice"))
        downloads.request(listOf(podcast(1)))
        transport.statuses[transport.idFor(1)] = TransferStatus.Succeeded("/files/1.mp3", 10, "audio/mpeg")
        downloads.sync()
        downloads.libraryChanged(account("alice", items = listOf(podcast(1, completed = true))))
        assertNotNull(downloads.record("episode-1")?.playedAt)
        downloads.libraryChanged(account("alice", items = listOf(podcast(1))))
        assertNull(downloads.record("episode-1")?.playedAt)
        downloads.libraryChanged(account("alice", items = listOf(podcast(1, completed = true))))
        now += DownloadPolicy.PLAYED_RETENTION_MS
        downloads.removeExpired()
        assertNull(downloads.record("episode-1"))
        assertTrue("/files/1.mp3" in transport.deleted)
    }

    @Test fun loweringTheLimitRemovesAutomaticButNotManual() {
        val downloads = downloads()
        downloads.libraryChanged(account("alice", listOf(podcast(1, show = "a"), podcast(2, show = "b"))))
        downloads.request(listOf(podcast(3)))
        assertEquals(3, downloads.records.value.size)
        downloads.updateSettings(DownloadSettings(limitBytes = hour))
        assertEquals(setOf("episode-3"), downloads.records.value.keys)
    }

    @Test fun anotherAccountOrSigningOutDiscardsEverything() {
        val downloads = downloads()
        downloads.libraryChanged(account("alice"))
        downloads.request(listOf(podcast(1)))
        val id = transport.idFor(1)
        downloads.libraryChanged(account("bob"))
        assertTrue(downloads.records.value.isEmpty())
        assertTrue(id in transport.removed)
        assertEquals("bob", manifests.saved.owner)
        downloads.request(listOf(podcast(2)))
        downloads.libraryChanged(LibraryState(live = false))
        assertTrue(downloads.records.value.isEmpty())
        assertNull(manifests.saved.owner)
    }

    @Test fun failuresAreReportedAndCanBeRetried() {
        val downloads = downloads()
        downloads.request(listOf(podcast(1)))
        transport.statuses[transport.idFor(1)] = TransferStatus.Failed("Lost")
        downloads.sync()
        assertEquals(DownloadStatus.Failed("Lost"), downloads.record("episode-1")?.status)
        assertEquals(0L, downloads.usedBytes)
        assertTrue(downloads.request(listOf(podcast(1))) is DownloadDecision.Started)
    }

    @Test fun aWebPageIsNotAudio() {
        val downloads = downloads()
        downloads.request(listOf(podcast(1)))
        transport.statuses[transport.idFor(1)] = TransferStatus.Succeeded("/files/1.mp3", 10, "text/html")
        downloads.sync()
        assertTrue(downloads.record("episode-1")?.status is DownloadStatus.Failed)
    }

    @Test fun aTransferTheSystemLostStartsAgain() {
        val downloads = downloads()
        downloads.request(listOf(podcast(1)))
        transport.statuses[transport.idFor(1)] = TransferStatus.Missing
        downloads.sync()
        assertEquals(2, transport.started.size)
        assertEquals(transport.started.last().first, downloads.record("episode-1")?.transferId)
    }

    @Test fun aVoiceQuestionIsAnsweredOnceAndExpires() {
        mobile = true
        val downloads = downloads()
        val confirmation = (downloads.request(listOf(podcast(1))) as DownloadDecision.NeedsConfirmation).confirmation
        downloads.awaitVoiceAnswer(confirmation)
        assertEquals(confirmation, downloads.takeVoiceQuestion())
        assertNull(downloads.takeVoiceQuestion())
        downloads.awaitVoiceAnswer(confirmation)
        now += 121_000
        assertNull(downloads.takeVoiceQuestion())
    }
}
