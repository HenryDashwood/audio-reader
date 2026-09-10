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

    @Test fun emptyAndWhitespaceArticlesHaveNoTimeline() {
        assertTrue(articleChunks(" \n\n ").isEmpty())
        assertNull(bookmarkAt(emptyList(), 1000, "v1"))
        assertEquals(0L, resumeAt(emptyList(), ArticleBookmark("v1", 10), "v1"))
    }
}
