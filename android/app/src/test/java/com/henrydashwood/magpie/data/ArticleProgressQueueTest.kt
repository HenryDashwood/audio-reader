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
class ArticleProgressQueueTest {
    private val text = "e".repeat(64)
    private val a = "a".repeat(64)
    private val b = "b".repeat(64)
    private val c = "c".repeat(64)
    private class Store : ArticleProgressStore {
        val owners = mutableMapOf<String, List<QueuedArticleProgress>>()
        override suspend fun read(owner: String) = owners[owner].orEmpty()
        override suspend fun write(owner: String, entries: List<QueuedArticleProgress>) { owners[owner] = entries }
    }
    private fun receipt(revision: String, offset: Int = 10, completed: Boolean = false, accepted: String = revision) =
        ArticleProgressReceipt(RemoteEpisode(1, "Article", completed = completed,
            articleBookmark = RemoteArticleBookmark(text, offset)), ArticleProgressState(text, null, revision, RemoteArticleBookmark(text, offset)), accepted)
    private suspend fun ArticleProgressQueue.begin(playback: String = "first", revision: String = a) =
        start("alice", 1, playback, revision, ArticleProgressSample(text, null, 0), false)
    private suspend fun ArticleProgressQueue.record(offset: Int, completed: Boolean = false, playback: String = "first") =
        record("alice", 1, playback, ArticleProgressSample(text, null, offset, completed))
    private suspend fun ArticleProgressQueue.flush(send: suspend (Int, ArticleProgressReport) -> ArticleProgressReceipt) =
        flush("alice", { true }, send) { _, _, _ -> }

    @Test fun preparationDoesNotUploadZeroAndRecreationRetainsExactLostReplyRequest() = runTest {
        val store = Store(); val queue = ArticleProgressQueue(store)
        queue.begin(); queue.flush { _, _ -> error("Preparation must not report") }
        queue.record(10)
        var original: ArticleProgressReport? = null
        try { queue.flush { _, report -> original = report; throw IOException("lost reply") }; fail() } catch (_: IOException) { }
        queue.record(20)
        val recreated = ArticleProgressQueue(store)
        recreated.flush { _, report -> assertEquals(original, report); receipt(b) }
        val tail = recreated.entries("alice").single().pending!!
        assertNotEquals(original!!.requestId, tail.requestId)
        assertEquals(b, tail.expectedRevision); assertEquals(20, tail.offsetUtf16)
        recreated.flush { _, report -> assertEquals(tail, report); receipt(c, 20) }
        assertNull(recreated.entries("alice").single().pending)
    }
    @Test fun completionWinsOverLatePauseAndWaitsBehindImmutableHead() = runTest {
        val queue = ArticleProgressQueue(Store()); queue.begin(); queue.record(10)
        queue.record(100, true)
        assertFalse(queue.record(99))
        queue.flush { _, report -> assertFalse(report.completed); receipt(b) }
        queue.flush { _, report -> assertTrue(report.completed); assertEquals(b, report.expectedRevision); receipt(c, 100, true) }
        assertTrue(queue.entries("alice").single().latest.completed)
    }
    @Test fun newerRemoteFilingBlocksAllOldClockReportsIncludingAfterRecreation() = runTest {
        val store = Store(); val queue = ArticleProgressQueue(store); queue.begin(); queue.record(10)
        queue.record(20)
        var changed = false
        queue.flush("alice", { true }, { _, _ -> receipt(c, 0, true, b) }) { _, _, conflict -> changed = conflict }
        assertTrue(changed); assertTrue(queue.entries("alice").single().blocked)
        val recreated = ArticleProgressQueue(store)
        assertFalse(recreated.record(30))
        recreated.flush { _, _ -> error("Old playback must stay blocked") }
        recreated.begin("new", c); recreated.record(5, playback = "new")
        recreated.flush { _, report -> assertEquals(c, report.expectedRevision); receipt(a, 5) }
    }
    @Test fun conflictFetchKeepsCanonicalStateAndNeverBlindlyRebases() = runTest {
        val queue = ArticleProgressQueue(Store()); queue.begin(); queue.record(10)
        queue.flush { _, _ -> throw ArticleProgressConflict(receipt(c, 0, true).episode, receipt(c, 0, true).progress) }
        assertTrue(queue.entries("alice").single().blocked)
        assertFalse(queue.record(20))
    }
    @Test fun filingDuringInflightWriteDiscardsLateAcknowledgement() = runTest {
        val queue = ArticleProgressQueue(Store()); queue.begin(); queue.record(10)
        val gate = CompletableDeferred<Unit>(); var callbacks = 0
        val upload = launch { queue.flush("alice", { true }, { _, _ -> gate.await(); receipt(b) }) { _, _, _ -> callbacks++ } }
        runCurrent(); queue.block("alice", setOf(1))
        gate.complete(Unit); upload.join()
        assertEquals(0, callbacks); assertNull(queue.entries("alice").single().pending)
    }
    @Test fun durableRequestGuardsSurviveRestartAndExplicitPlayUntilMatchingConfirmation() = runTest {
        val store = Store(); val queue = ArticleProgressQueue(store); queue.begin(); queue.record(10)
        queue.hold("alice", setOf(1), "request-one"); queue.hold("alice", setOf(1), "request-two")
        val recreated = ArticleProgressQueue(store); recreated.begin("new", a)
        recreated.confirm("alice", "request-one")
        assertFalse(recreated.record(20, playback = "new"))
        recreated.flush { _, _ -> error("Uncertain filing must block progress") }
        recreated.confirm("alice", "request-two")
        assertTrue(recreated.record(20, playback = "new"))
        recreated.flush { _, report -> assertEquals(10, report.offsetUtf16); receipt(b) }
        assertEquals(20, recreated.entries("alice").single().pending!!.offsetUtf16)
    }
    @Test fun holdDoesNotCancelAlreadySentWriteAndDrainWaitsForIt() = runTest {
        val queue = ArticleProgressQueue(Store()); queue.begin(); queue.record(10)
        val gate = CompletableDeferred<Unit>()
        val upload = launch { queue.flush { _, _ -> gate.await(); receipt(b) } }
        runCurrent(); queue.hold("alice", setOf(1), "filing")
        var drained = false
        val drain = launch { queue.awaitNetwork(); drained = true }
        runCurrent(); assertFalse(drained)
        gate.complete(Unit); upload.join(); drain.join()
        assertTrue(drained); assertEquals(b, queue.entries("alice").single().baselineRevision)
        assertFalse(queue.record(20))
    }
    @Test fun newerExplicitIntentKeepsItsKnownRevisionWhenOldReceiptReturnsConflict() = runTest {
        val queue = ArticleProgressQueue(Store()); queue.begin(); queue.record(10)
        queue.begin("new", c); queue.record(5, playback = "new")
        queue.flush { _, _ -> receipt(c, 0, true, b) }
        val entry = queue.entries("alice").single()
        assertFalse(entry.blocked); assertEquals(c, entry.pending!!.expectedRevision)
        assertEquals(5, entry.pending.offsetUtf16)
    }
    @Test fun oldReplyCannotReplaceFilingMetadataOfNewerExplicitPlayback() = runTest {
        val queue = ArticleProgressQueue(Store()); queue.begin(); queue.record(10)
        val gate = CompletableDeferred<Unit>()
        val upload = launch { queue.flush { _, _ -> gate.await(); receipt(b) } }
        runCurrent()
        queue.start("alice", 1, "new", c, ArticleProgressSample(text, null, 5), dismissed = true)
        queue.record(6, playback = "new")
        gate.complete(Unit); upload.join()
        val entry = queue.entries("alice").single()
        assertEquals(c, entry.baselineRevision); assertTrue(entry.dismissed)
        assertEquals(c, entry.pending!!.expectedRevision)
    }
    @Test fun changedTextCannotLendItsVersionOrOffsetToAnOlderPendingRequest() = runTest {
        val queue = ArticleProgressQueue(Store()); queue.begin(); queue.record(10)
        val replacement = "f".repeat(64)
        queue.start("alice", 1, "replacement", c, ArticleProgressSample(replacement, 42, 0), false)
        assertFalse(queue.record("alice", 1, "replacement", ArticleProgressSample(text, null, 20)))
        queue.record("alice", 1, "replacement", ArticleProgressSample(replacement, 42, 7))
        queue.flush { _, report ->
            assertEquals(text, report.textVersion); assertNull(report.contentId); assertEquals(10, report.offsetUtf16)
            ArticleProgressReceipt(RemoteEpisode(1, "Replacement", contentId = 42), ArticleProgressState(replacement, 42, c, null), b)
        }
        val pending = queue.entries("alice").single().pending!!
        assertEquals(replacement, pending.textVersion); assertEquals(42, pending.contentId)
        assertEquals(7, pending.offsetUtf16); assertEquals(c, pending.expectedRevision)
    }
    @Test fun changedTextBlocksOldPlaybackEvenWhenItHasMoreSamples() = runTest {
        val queue = ArticleProgressQueue(Store()); queue.begin(); queue.record(10); queue.record(20)
        queue.flush { _, _ -> ArticleProgressReceipt(RemoteEpisode(1, "Replacement", contentId = 42),
            ArticleProgressState("f".repeat(64), 42, c, null), b) }
        assertTrue(queue.entries("alice").single().blocked)
        assertFalse(queue.record(30))
    }
    @Test fun accountChangeWhileSendingCannotRepopulateClearedJournalOrPublishReceipt() = runTest {
        val queue = ArticleProgressQueue(Store()); queue.begin(); queue.record(10)
        var valid = true; val gate = CompletableDeferred<Unit>(); var applied = false
        val upload = launch { queue.flush("alice", { valid }, { _, _ -> gate.await(); receipt(b) }) { _, _, _ -> applied = true } }
        runCurrent(); valid = false; queue.clear("alice")
        queue.start("bob", 1, "bob-play", c, ArticleProgressSample(text, null, 50), false)
        gate.complete(Unit); upload.join()
        assertTrue(queue.entries("alice").isEmpty()); assertFalse(applied)
        assertEquals(50, queue.entries("bob").single().latest.offsetUtf16)
    }
}
