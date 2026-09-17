package com.henrydashwood.magpie.data

import java.io.IOException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.*
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class PodcastProgressQueueTest {
    private val a = "a".repeat(64)
    private val b = "b".repeat(64)
    private val c = "c".repeat(64)
    private class Store : PodcastProgressStore {
        val owners = mutableMapOf<String, List<QueuedPodcastProgress>>()
        override suspend fun read(owner: String) = owners[owner].orEmpty()
        override suspend fun write(owner: String, entries: List<QueuedPodcastProgress>) { owners[owner] = entries }
    }
    private fun receipt(revision: String, seconds: Double = 10.0, completed: Boolean = false, accepted: String = revision) =
        PodcastProgressReceipt(RemoteEpisode(1, "Podcast", audioUrl = "https://example.invalid/audio", positionSeconds = seconds,
            completed = completed, progressRevision = revision), accepted)
    private suspend fun PodcastProgressQueue.begin(playback: String = "first", revision: String = a) =
        start("alice", 1, playback, revision, ProgressSample(0.0), false)
    private suspend fun PodcastProgressQueue.record(seconds: Double, completed: Boolean = false, playback: String = "first") =
        record("alice", 1, playback, ProgressSample(seconds, completed))
    private suspend fun PodcastProgressQueue.flush(send: suspend (Int, PodcastProgressReport) -> PodcastProgressReceipt) =
        flush("alice", { true }, send) { _, _ -> }

    @Test fun preparationDoesNotUploadZeroAndRecreationRetainsExactLostReplyRequest() = runTest {
        val store = Store(); val queue = PodcastProgressQueue(store)
        queue.begin(); queue.flush { _, _ -> error("Preparation must not report") }
        queue.record(10.0)
        var original: PodcastProgressReport? = null
        try { queue.flush { _, report -> original = report; throw IOException("lost reply") }; fail() } catch (_: IOException) { }
        queue.record(20.0)
        val recreated = PodcastProgressQueue(store)
        recreated.flush { _, report -> assertEquals(original, report); receipt(b) }
        val tail = recreated.entries("alice").single().pending!!
        assertNotEquals(original!!.requestId, tail.requestId)
        assertEquals(b, tail.expectedRevision); assertEquals(20.0, tail.seconds, 0.0)
        recreated.flush { _, report -> assertEquals(tail, report); receipt(c, 20.0) }
        assertNull(recreated.entries("alice").single().pending)
    }
    @Test fun completionWinsOverLatePauseAndWaitsBehindImmutableHead() = runTest {
        val queue = PodcastProgressQueue(Store()); queue.begin(); queue.record(10.0)
        queue.record(100.0, true)
        assertFalse(queue.record(99.0))
        queue.flush { _, report -> assertFalse(report.completed); receipt(b) }
        queue.flush { _, report -> assertTrue(report.completed); assertEquals(b, report.expectedRevision); receipt(c, 100.0, true) }
        assertTrue(queue.entries("alice").single().latest.completed)
    }
    @Test fun newerRemoteFilingBlocksAllOldClockReportsIncludingAfterRecreation() = runTest {
        val store = Store(); val queue = PodcastProgressQueue(store); queue.begin(); queue.record(10.0)
        queue.record(20.0)
        var changed = false
        queue.flush("alice", { true }, { _, _ -> receipt(c, 0.0, true, b) }) { _, conflict -> changed = conflict }
        assertTrue(changed); assertTrue(queue.entries("alice").single().blocked)
        val recreated = PodcastProgressQueue(store)
        assertFalse(recreated.record(30.0))
        recreated.flush { _, _ -> error("Old playback must stay blocked") }
        recreated.begin("new", c); recreated.record(5.0, playback = "new")
        recreated.flush { _, report -> assertEquals(c, report.expectedRevision); receipt(a, 5.0) }
    }
    @Test fun conflictFetchKeepsCanonicalStateAndNeverBlindlyRebases() = runTest {
        val queue = PodcastProgressQueue(Store()); queue.begin(); queue.record(10.0)
        queue.flush { _, _ -> throw ProgressConflict(receipt(c, 0.0, true).episode) }
        assertTrue(queue.entries("alice").single().blocked)
        assertFalse(queue.record(20.0))
    }
    @Test fun filingDuringInflightWriteDiscardsLateAcknowledgement() = runTest {
        val queue = PodcastProgressQueue(Store()); queue.begin(); queue.record(10.0)
        val gate = CompletableDeferred<Unit>(); var callbacks = 0
        val upload = launch { queue.flush("alice", { true }, { _, _ -> gate.await(); receipt(b) }) { _, _ -> callbacks++ } }
        runCurrent(); queue.block("alice", setOf(1))
        gate.complete(Unit); upload.join()
        assertEquals(0, callbacks); assertNull(queue.entries("alice").single().pending)
    }
    @Test fun durableRequestGuardsSurviveRestartAndExplicitPlayUntilMatchingConfirmation() = runTest {
        val store = Store(); val queue = PodcastProgressQueue(store); queue.begin(); queue.record(10.0)
        queue.hold("alice", setOf(1), "request-one"); queue.hold("alice", setOf(1), "request-two")
        val recreated = PodcastProgressQueue(store); recreated.begin("new", a)
        recreated.confirm("alice", "request-one")
        assertFalse(recreated.record(20.0, playback = "new"))
        recreated.flush { _, _ -> error("Uncertain filing must block progress") }
        recreated.confirm("alice", "request-two")
        assertTrue(recreated.record(20.0, playback = "new"))
        recreated.flush { _, report -> assertEquals(10.0, report.seconds, 0.0); receipt(b) }
        assertEquals(20.0, recreated.entries("alice").single().pending!!.seconds, 0.0)
    }
    @Test fun holdDoesNotCancelAlreadySentWriteAndDrainWaitsForIt() = runTest {
        val queue = PodcastProgressQueue(Store()); queue.begin(); queue.record(10.0)
        val gate = CompletableDeferred<Unit>()
        val upload = launch { queue.flush { _, _ -> gate.await(); receipt(b) } }
        runCurrent(); queue.hold("alice", setOf(1), "filing")
        var drained = false
        val drain = launch { queue.awaitNetwork(); drained = true }
        runCurrent(); assertFalse(drained)
        gate.complete(Unit); upload.join(); drain.join()
        assertTrue(drained); assertEquals(b, queue.entries("alice").single().baselineRevision)
        assertFalse(queue.record(20.0))
    }
    @Test fun newerExplicitIntentKeepsItsKnownRevisionWhenOldReceiptReturnsConflict() = runTest {
        val queue = PodcastProgressQueue(Store()); queue.begin(); queue.record(10.0)
        queue.begin("new", c); queue.record(5.0, playback = "new")
        queue.flush { _, _ -> receipt(c, 0.0, true, b) }
        val entry = queue.entries("alice").single()
        assertFalse(entry.blocked); assertEquals(c, entry.pending!!.expectedRevision)
        assertEquals(5.0, entry.pending.seconds, 0.0)
    }
    @Test fun oldReplyCannotReplaceFilingMetadataOfNewerExplicitPlayback() = runTest {
        val queue = PodcastProgressQueue(Store()); queue.begin(); queue.record(10.0)
        val gate = CompletableDeferred<Unit>()
        val upload = launch { queue.flush { _, _ -> gate.await(); receipt(b) } }
        runCurrent()
        queue.start("alice", 1, "new", c, ProgressSample(5.0), dismissed = true)
        queue.record(6.0, playback = "new")
        gate.complete(Unit); upload.join()
        val entry = queue.entries("alice").single()
        assertEquals(c, entry.baselineRevision); assertTrue(entry.dismissed)
        assertEquals(c, entry.pending!!.expectedRevision)
    }
    @Test fun accountChangeWhileSendingCannotRepopulateClearedJournalOrPublishReceipt() = runTest {
        val queue = PodcastProgressQueue(Store()); queue.begin(); queue.record(10.0)
        var valid = true; val gate = CompletableDeferred<Unit>(); var applied = false
        val upload = launch { queue.flush("alice", { valid }, { _, _ -> gate.await(); receipt(b) }) { _, _ -> applied = true } }
        runCurrent(); valid = false; queue.clear("alice")
        queue.start("bob", 1, "bob-play", c, ProgressSample(50.0), false)
        gate.complete(Unit); upload.join()
        assertTrue(queue.entries("alice").isEmpty()); assertFalse(applied)
        assertEquals(50.0, queue.entries("bob").single().latest.seconds, 0.0)
    }
}
