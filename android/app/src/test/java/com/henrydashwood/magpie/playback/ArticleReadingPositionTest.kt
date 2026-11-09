package com.henrydashwood.magpie.playback

import org.junit.Assert.*
import org.junit.Test

class ArticleReadingPositionTest {
    @Test fun sentenceFallbackKeepsExactUnicodeOffsetsAndBoundsLongSentences() {
        val text = "  First café 🐦. Another sentence.\n\n" + "word ".repeat(150) + "."
        val chunks = articleNarrationChunks(text, 100)
        assertEquals("First café 🐦.", chunks[0].text)
        assertEquals("Another sentence.", chunks[1].text)
        assertTrue(chunks.all { it.text.length <= 100 })
        chunks.forEach { assertEquals(it.text, text.substring(it.startUtf16, it.endUtf16)) }
        assertEquals(text.filterNot(Char::isWhitespace), chunks.joinToString("") { it.text }.filterNot(Char::isWhitespace))
    }

    @Test fun sampleFramesMapToMediaTimeAndOriginalUtf16Offsets() {
        val chunk = TimedChunk(TextChunk("🐦 Hello café", 17, 30), 2500, 5500)
        val ranges = timedSpeechRanges(chunk, listOf(SpeechFrame(24000, 3, 8), SpeechFrame(48000, 9, 13)), 24000)
        assertEquals(listOf(TimedSpeechRange(3500, 20, 25), TimedSpeechRange(4500, 26, 30)), ranges)
        assertEquals(20, readingRangeAt(listOf(chunk), ranges, 4200)!!.startUtf16)
        assertEquals(26, readingRangeAt(listOf(chunk), ranges, 4900)!!.startUtf16)
        // A backward seek finds the earlier word; no accumulated wall-clock state.
        assertEquals(20, readingRangeAt(listOf(chunk), ranges, 3700)!!.startUtf16)
    }

    @Test fun rotatedGoogleEngineRangesAreReordered() {
        // Values as delivered by Google's engine on a Pixel 10a: SpeechFrame(frame, start, end)
        // received (text end, audio frame, text start).
        val chunk = TimedChunk(TextChunk("The price is high", 100, 117), 0, 2000)
        val received = listOf(SpeechFrame(3, 360, 0), SpeechFrame(9, 4800, 4), SpeechFrame(12, 12000, 10), SpeechFrame(17, 24000, 13))
        assertEquals(listOf(TimedSpeechRange(15, 100, 103), TimedSpeechRange(200, 104, 109),
            TimedSpeechRange(500, 110, 112), TimedSpeechRange(1000, 113, 117)), timedSpeechRanges(chunk, received, 24000))
        // Documented-order ranges are never rotated, even when the rotation would also fit.
        assertEquals(listOf(SpeechFrame(1, 2, 3)), engineSpeechFrames(listOf(SpeechFrame(1, 2, 3)), 5))
    }

    @Test fun missingOrInvalidTimingsFallBackToTheCurrentChunk() {
        val first = TimedChunk(TextChunk("First", 0, 5), 0, 1000)
        val second = TimedChunk(TextChunk("Second", 7, 13), 1000, 2000)
        val invalid = listOf(SpeechFrame(-1, 0, 2), SpeechFrame(0, -1, 2), SpeechFrame(0, 0, 99), SpeechFrame(100000, 0, 2))
        assertTrue(timedSpeechRanges(first, invalid, 24000).isEmpty())
        assertTrue(timedSpeechRanges(first, listOf(SpeechFrame(0, 0, 2)), 0).isEmpty())
        assertEquals(7, readingRangeAt(listOf(first, second), listOf(TimedSpeechRange(500, 2, 5)), 1200)!!.startUtf16)
        assertNull(readingRangeAt(emptyList(), emptyList(), 0))
    }

    @Test fun theMarkerWakesWhenTheNextWordIsDue() {
        val chunk = TimedChunk(TextChunk("one two three", 0, 13), 1_000, 3_000)
        val ranges = listOf(TimedSpeechRange(1_000, 0, 3), TimedSpeechRange(1_250, 4, 7), TimedSpeechRange(1_500, 8, 13))
        assertEquals(100, msUntilNextWord(ranges, chunk, 1_000, 2f, 100))  // 125 ms away: capped at 100
        assertEquals(51, msUntilNextWord(ranges, chunk, 1_150, 2f, 100))  // 100 ms of audio at 2x
        assertEquals(4, msUntilNextWord(ranges, chunk, 1_249, 2f, 100))  // Due now: the next pass, not a busy loop
        assertEquals(100, msUntilNextWord(ranges, chunk, 1_600, 1f, 100))  // Only the passage's end left, far off
        assertEquals(41, msUntilNextWord(ranges, chunk, 2_960, 1f, 100))  // The passage's end
        assertEquals(100, msUntilNextWord(emptyList(), chunk, 3_500, 1f, 100))
    }

    @Test fun thePositionRunsOnBetweenThePlayersSteps() {
        val clock = SmoothedPosition(cap = 400)
        assertEquals(10_000, clock.position(10_000, true, 2f, 1_000))
        assertEquals(10_100, clock.position(10_000, true, 2f, 1_050))  // 50 ms later at 2x
        assertEquals(10_240, clock.position(10_000, true, 2f, 1_120))
        assertEquals(10_250, clock.position(10_250, true, 2f, 1_125))  // The player's next step resets it
        assertEquals(10_650, clock.position(10_250, true, 2f, 2_000))  // A late step: no further than the cap
        assertEquals(10_250, clock.position(10_250, false, 2f, 2_100))  // Paused: what the player says
        assertEquals(10_250, clock.position(10_250, true, 2f, 2_100))
        assertEquals(5_000, clock.position(5_000, true, 2f, 2_200))  // A seek back
    }
}
