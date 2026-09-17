package com.henrydashwood.magpie

import androidx.test.core.app.ApplicationProvider
import com.henrydashwood.magpie.data.RemoteEpisode
import com.henrydashwood.magpie.voice.*
import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.util.UUID

class FileConversationStoreTest {
    @Test fun freshStoresPreserveExactRequestContextAndCompoundReceiptForEachAccount() = runBlocking {
        val app = ApplicationProvider.getApplicationContext<MagpieTestApplication>()
        val directory = File(app.noBackupFilesDir, "voice-journal-test-${UUID.randomUUID()}")
        val owner = "a".repeat(64); val other = "b".repeat(64)
        try {
            val request = VoiceRequest("Find café 🌱", "original-request", 17, 19,
                listOf(ConversationTurn("her", "Which one?"), ConversationTurn("app", "This one.")), listOf("played: One"), "GB")
            val episode = RemoteEpisode(17, "Café", "Description", "Newsletter", "https://example.com/feed",
                "https://example.com/audio", "https://example.com/story", 90, 30, 12.5, true, true, 4, "Error", "c".repeat(64))
            val response = VoiceResponse(VoiceAction.Unknown, "Finished", expectsReply = true, actions = listOf(
                VoiceResponse(VoiceAction.Played, "Filed", episode), VoiceResponse(VoiceAction.Speed, "Faster", speed = 1.5f),
                VoiceResponse(VoiceAction.Restore, "Restored article", RemoteEpisode(19, "Article", contentId = 7,
                    articleBookmark = com.henrydashwood.magpie.data.RemoteArticleBookmark("d".repeat(64), 9),
                    publishedAt = "2026-09-17T09:00:00Z", imageUrl = "https://example.com/cover.png"))))
            val entries = listOf(RecoverableVoiceRequest(request, response), RecoverableVoiceRequest(VoiceRequest("Another", "another")))
            FileConversationStore(directory).write(owner, entries)
            FileConversationStore(directory).write(other, entries.takeLast(1))
            val fresh = FileConversationStore(directory)
            assertEquals(entries, fresh.read(owner)); assertEquals(entries.takeLast(1), fresh.read(other))
            val target = File(directory, "$owner.json")
            val legacy = JSONObject(target.readText())
            assertEquals(2, legacy.getInt("schema"))
            target.writeText(legacy.put("schema", 1).toString())
            assertEquals(entries, fresh.read(owner))
            assertEquals(VoiceWire.request(request).toString(), VoiceWire.request(fresh.read(owner).first().request).toString())
            fresh.write(owner, emptyList()); assertTrue(fresh.read(owner).isEmpty()); assertEquals(1, fresh.read(other).size)
        } finally { directory.deleteRecursively() }
    }
    @Test fun typedTargetsAndUndoReceiptsRoundTripWithoutBecomingFreeFormRequests() = runBlocking {
        val app = ApplicationProvider.getApplicationContext<MagpieTestApplication>()
        val directory = File(app.noBackupFilesDir, "typed-journal-test-${UUID.randomUUID()}")
        val owner = "a".repeat(64)
        try {
            val requests = listOf(
                RecoverableVoiceRequest(VoiceRequest("Mark as played: A story", "typed-current"), structured = StructuredLibraryRequest("mark_played", 17, true)),
                RecoverableVoiceRequest(VoiceRequest("Undo the last library change", "typed-undo"),
                    VoiceResponse(VoiceAction.Restore, "Restored.", RemoteEpisode(17, "Story")), StructuredLibraryRequest("undo", null)))
            FileConversationStore(directory).write(owner, requests)
            assertEquals(requests, FileConversationStore(directory).read(owner))
            val target = File(directory, "$owner.json")
            val corrupt = JSONObject(target.readText())
            assertEquals("Readers without typed routes must fail closed", 2, corrupt.getInt("schema"))
            corrupt.getJSONArray("requests").getJSONObject(0).getJSONObject("structured").put("action", "not-supported")
            target.writeText(corrupt.toString())
            assertTrue(runCatching { FileConversationStore(directory).read(owner) }.isFailure)
            assertEquals(corrupt.toString(), target.readText())
        } finally { directory.deleteRecursively() }
    }
    @Test fun corruptFutureAndForeignJournalsRemainUntouchedAndFailClosed() = runBlocking {
        val app = ApplicationProvider.getApplicationContext<MagpieTestApplication>()
        val directory = File(app.noBackupFilesDir, "voice-journal-test-${UUID.randomUUID()}")
        val owner = "a".repeat(64); val other = "b".repeat(64)
        try {
            val store = FileConversationStore(directory)
            val requests = listOf(RecoverableVoiceRequest(VoiceRequest("Private")))
            store.write(other, requests); directory.mkdirs()
            val target = File(directory, "$owner.json")
            for (raw in listOf("{broken", """{"schema":999,"owner":"$owner","requests":[]}""",
                """{"schema":1,"owner":"$other","requests":[]}""")) {
                target.writeText(raw)
                assertTrue(runCatching { store.read(owner) }.isFailure)
                assertEquals(raw, target.readText()); assertEquals(requests, store.read(other))
            }
            store.write(owner, requests)
            val malformedReceipt = JSONObject(target.readText())
            malformedReceipt.getJSONArray("requests").getJSONObject(0).put("receipt", "broken")
            target.writeText(malformedReceipt.toString())
            assertTrue(runCatching { store.read(owner) }.isFailure)
            assertEquals(malformedReceipt.toString(), target.readText())
            assertTrue(runCatching { store.read("../outside") }.isFailure)
        } finally { directory.deleteRecursively() }
    }
}
