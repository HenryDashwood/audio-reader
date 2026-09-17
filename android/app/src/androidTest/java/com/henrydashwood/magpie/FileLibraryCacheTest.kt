package com.henrydashwood.magpie

import androidx.test.core.app.ApplicationProvider
import com.henrydashwood.magpie.data.*
import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.util.UUID

class FileLibraryCacheTest {
    private fun snapshot(owner: String): LibrarySnapshot {
        val article = LibraryItem("$owner:episode:2", "Letters", "A café 🌱", "Description", ContentKind.Article,
            "3 min", "Immutable speech text 😀", "sha256-text", "https://example.com/article", "<p>Immutable speech text 😀</p>",
            2, 77, "10", null, 100, true, 0, true, false, null, null,
            publishedAt = "2026-09-17T10:00:00Z", imageUrl = "https://example.com/article.png",
            articleBookmark = RemoteArticleBookmark("e".repeat(64), 12),
            articleProgress = ArticleProgressState("e".repeat(64), 77, "f".repeat(64), RemoteArticleBookmark("e".repeat(64), 12)))
        val podcast = LibraryItem("$owner:episode:3", "Podcast", "An episode", "Summary", ContentKind.Podcast,
            "5 min", "Summary", episodeId = 3, sourceId = "20", audioUrl = "https://example.com/audio.mp3",
            remotePositionMs = 12345, dismissed = true, captureError = "Capture failed", durationSeconds = 300, progressRevision = "c".repeat(64))
        return LibrarySnapshot(owner, listOf(article, podcast), listOf(LibraryFeed("10", "Letters", 1, true,
            "https://example.com/feed", listOf("Primary", "Second"), "A publication", listOf(FeedSource("10", "Primary",
                "https://example.com/private-feed", "email", true, true)), true, "https://example.com/feed.png")),
            listOf(podcast.id), listOf(article.id), mapOf("10" to listOf(article.id), "empty" to emptyList()))
    }
    @Test fun everyFieldSurvivesAFreshStoreAndAccountsRemainSeparate() = runBlocking {
        val app = ApplicationProvider.getApplicationContext<MagpieTestApplication>()
        val directory = File(app.noBackupFilesDir, "cache-test-${UUID.randomUUID()}")
        try {
            val first = snapshot("a".repeat(64)); val second = snapshot("b".repeat(64))
            val cache = FileLibraryCache(directory)
            cache.save(first); cache.save(second)
            val reopened = FileLibraryCache(directory)
            assertEquals(first, reopened.load(first.owner)); assertEquals(second, reopened.load(second.owner))
            cache.save(first.copy(items = first.items.map { it.copy(title = "Changed") }, savedIds = emptyList()))
            assertEquals("Changed", reopened.load(first.owner)!!.items.first().title)
            assertTrue(reopened.load(first.owner)!!.savedIds.isEmpty())
            cache.clear(first.owner)
            assertNull(reopened.load(first.owner)); assertEquals(second, reopened.load(second.owner))
            try { cache.load("../outside"); fail("Unsafe owner accepted") } catch (_: IllegalArgumentException) { }
        } finally { directory.deleteRecursively() }
    }
    @Test fun corruptFutureOrForeignSnapshotsAreDiscardedWithoutAffectingAnotherAccount() = runBlocking {
        val app = ApplicationProvider.getApplicationContext<MagpieTestApplication>()
        val directory = File(app.noBackupFilesDir, "cache-test-${UUID.randomUUID()}")
        try {
            val first = snapshot("a".repeat(64)); val second = snapshot("b".repeat(64))
            val cache = FileLibraryCache(directory); cache.save(second)
            val target = File(directory, "${first.owner}.json")
            target.writeText("{broken"); assertNull(cache.load(first.owner)); assertFalse(target.exists())
            cache.save(first)
            target.writeText(JSONObject(target.readText()).put("schema", 999).toString())
            assertNull(cache.load(first.owner))
            cache.save(first)
            target.writeText(JSONObject(target.readText()).put("owner", second.owner).toString())
            assertNull(cache.load(first.owner))
            cache.save(first)
            val invalid = JSONObject(target.readText())
            invalid.getJSONArray("items").getJSONObject(0).put("id", "${second.owner}:episode:2")
            target.writeText(invalid.toString()); assertNull(cache.load(first.owner))
            assertEquals(second, cache.load(second.owner))
        } finally { directory.deleteRecursively() }
    }
}
