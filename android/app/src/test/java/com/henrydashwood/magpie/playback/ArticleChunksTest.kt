package com.henrydashwood.magpie.playback

import org.junit.Assert.*
import org.junit.Test

class ArticleChunksTest {
    @Test fun longUnbrokenTextAndEmojiRespectEngineLimitAndOriginalOffsets() {
        val text = "  A story 🐦 " + "x".repeat(1400) + "\n\nAnother paragraph."
        val chunks = articleChunks(text, 31)
        assertTrue(chunks.size > 40)
        assertTrue(chunks.all { it.text.length <= 31 })
        assertTrue(chunks.none { Character.isHighSurrogate(it.text.last()) || Character.isLowSurrogate(it.text.first()) })
        chunks.forEach { assertEquals(it.text, text.substring(it.startUtf16, it.endUtf16)) }
        assertEquals(text.filterNot(Char::isWhitespace), chunks.joinToString("") { it.text }.filterNot(Char::isWhitespace))
    }

    @Test fun bookmarksSurviveDifferentNarrationDurationsButRejectChangedContent() {
        val text = listOf(TextChunk("First.", 0, 6), TextChunk("Second.", 8, 15))
        val firstVoice = listOf(TimedChunk(text[0], 0, 1000), TimedChunk(text[1], 1000, 2000))
        val secondVoice = listOf(TimedChunk(text[0], 0, 3000), TimedChunk(text[1], 3000, 8000))
        val bookmark = bookmarkAt(firstVoice, 1500, "v1")
        assertEquals(8, bookmark?.offsetUtf16)
        assertEquals(3000L, resumeAt(secondVoice, bookmark, "v1"))
        assertEquals(0L, resumeAt(secondVoice, bookmark, "v2"))
    }

    @Test fun sharedIosCoordinateSelectsTheSameUnicodePassageWithDifferentVoiceDurations() {
        // Shared with iOS ArticleProgressJournalTests. No text normalization.
        val text = "Café 🌱 in the garden.\n\nAnother 🦉 passage beside the river.\n\nThe final paragraph."
        val version = java.security.MessageDigest.getInstance("SHA-256").digest(text.toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it) }
        assertEquals("8dbce6391279ec2806c0340ed5f585cdce28dcea1e0da494679c84d18dfc9a88", version)
        val chunks = articleNarrationChunks(text)
        val firstVoice = chunks.mapIndexed { index, chunk -> TimedChunk(chunk, index * 1000L, (index + 1) * 1000L) }
        val slowerVoice = chunks.mapIndexed { index, chunk -> TimedChunk(chunk, index * 4000L, (index + 1) * 4000L) }
        val bookmark = ArticleBookmark(version, 32)
        assertEquals(1000L, resumeAt(firstVoice, bookmark, version))
        assertEquals(4000L, resumeAt(slowerVoice, bookmark, version))
        assertEquals(24, bookmarkAt(slowerVoice, 4000, version)!!.offsetUtf16)
        assertTrue(chunks[1].text.startsWith("Another 🦉"))
    }

    @Test fun emptyAndWhitespaceArticlesHaveNoTimeline() {
        assertTrue(articleChunks(" \n\n ").isEmpty())
        assertNull(bookmarkAt(emptyList(), 1000, "v1"))
        assertEquals(0L, resumeAt(emptyList(), ArticleBookmark("v1", 10), "v1"))
    }
}
