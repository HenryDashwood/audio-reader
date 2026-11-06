package com.henrydashwood.magpie.playback

import java.io.File
import org.junit.Assert.*
import org.junit.Test

/** The steps around the natural voice's models, against the iOS app's tests of the same steps. */
class NaturalVoiceEngineTest {
    @Test fun wordsLandWhereKokoroPutsThem() {
        val tokens = listOf(
            listOf("Speed", "spˈiːd", " ", 0, 5), listOf("comes", "kˈʌmz", " ", 6, 11), listOf("from", "fɹɒm", " ", 12, 16),
            listOf("the", "ðə", " ", 17, 20), listOf("voice", "vˈYs", " ", 21, 26), listOf("itself", "ɪtsˈɛlf", "", 27, 33),
            listOf(",", ",", " ", 33, 34), listOf("not", "nˌɒt", " ", 35, 38), listOf("from", "fɹɒm", " ", 39, 43),
            listOf("stretching", "stɹˈɛʧɪŋ", " ", 44, 54), listOf("the", "ði", " ", 55, 58), listOf("audio", "ˈɔːdɪQ", " ", 59, 64),
            listOf("afterwards", "ˈɑːftəwədz", "", 65, 75), listOf(".", ".", "", 75, 76),
        ).map { PhonemeToken(it[0] as String, it[1] as String, it[2] as String, it[3] as Int, it[4] as Int) }
        val frames = listOf(
            14, 3, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1, 2, 2, 3, 3, 2, 2, 2, 3, 3, 3, 3, 4, 12, 3,
            2, 1, 2, 2, 1, 2, 1, 1, 2, 2, 2, 2, 2, 1, 2, 3, 3, 2, 1, 1, 1, 2, 2, 2, 1, 2, 3, 3, 2, 2, 2, 1, 2, 2, 2, 2,
            2, 3, 3, 23, 7, 1,
        )
        val expected = listOf(
            listOf(0, 5, 6600, 15000), listOf(6, 11, 15000, 22200), listOf(12, 16, 22200, 25500), listOf(17, 20, 25500, 27600),
            listOf(21, 26, 27600, 34800), listOf(27, 33, 34800, 53400), listOf(35, 38, 55800, 60600), listOf(39, 43, 60600, 65400),
            listOf(44, 54, 65400, 75900), listOf(55, 58, 75900, 78600), listOf(59, 64, 78600, 87600), listOf(65, 75, 87600, 113400),
        )
        val words = NaturalVoiceEngine.words(tokens, frames)
        assertEquals(expected, words.map { listOf(it.characters.first, it.characters.last + 1, it.samples.first, it.samples.last + 1) })
    }

    @Test fun trimmingKeepsALittleEitherSideAndMovesTheWords() {
        val trimmed = NaturalVoiceEngine.trimmed(FloatArray(48_000) { 0.5f }, listOf(NaturalVoiceEngine.Word(0 until 3, 12_000 until 24_000)))
        assertEquals(2_400 + 12_000 + 6_000, trimmed.samples.size)
        assertEquals(2_400 until 14_400, trimmed.words.single().samples)
    }

    @Test fun trimmingFollowsWhatIsHeardRatherThanTheWordTimings() {
        // Speech from 0.5 s to 0.8 s, though the word's timing runs on to 1 s, as Kokoro's last word does
        val samples = FloatArray(48_000) { if (it in 12_000 until 19_200) 0.5f else 0.001f }
        val trimmed = NaturalVoiceEngine.trimmed(samples, listOf(NaturalVoiceEngine.Word(0 until 3, 12_000 until 24_000)))
        assertEquals(1_200 + 7_200 + 4_800, trimmed.samples.size)
        assertEquals(1_200 until 13_200, trimmed.words.single().samples)
    }

    @Test fun paddingRepeatsTheSentence() {
        assertArrayEquals(floatArrayOf(1f, 2f, 3f, 1f, 2f, 3f, 1f), NaturalVoiceEngine.repeated(floatArrayOf(1f, 2f, 3f), 7), 0f)
    }

    @Test fun featuresAreRepeatedOncePerFrame() {
        // Two phonemes, three channels: as Tokens' d, (phonemes, channels)
        assertArrayEquals(floatArrayOf(1f, 1f, 4f, 2f, 2f, 5f, 3f, 3f, 6f),
            NaturalVoiceEngine.gather(floatArrayOf(1f, 2f, 3f, 4f, 5f, 6f), 2, 3, intArrayOf(0, 0, 1), transposing = true), 0f)
        // As Tokens' t_en, (channels, phonemes)
        assertArrayEquals(floatArrayOf(2f, 1f, 1f, 4f, 3f, 3f),
            NaturalVoiceEngine.gather(floatArrayOf(1f, 2f, 3f, 4f), 2, 2, intArrayOf(1, 0, 0), transposing = false), 0f)
    }

    @Test fun abbreviationsDoNotEndSentences() {
        val text = "Patreon paid on Thursday, from No. 10 Downing St. to St. Paul's. Then it rained. It was 3 p.m. on Jan. 4."
        val chunks = articleNarrationChunks(text)
        assertEquals(3, chunks.size)
        assertEquals("Patreon paid on Thursday, from No. 10 Downing St. to St. Paul's.", chunks.first().text)
        assertTrue(chunks.all { text.substring(it.startUtf16, it.endUtf16) == it.text && it.text.first().isUpperCase() })
    }

    @Test fun longSentencesSplitAtTheClauseNearestTheMiddle() {
        val text = "This is the first half of it, and this is the second half of the sentence"
        assertEquals("This is the first half of it, ", text.substring(0, NaturalArticleVoice.splitPoint(text)!!))
        val plain = "one two three four five six"
        assertEquals("one two three ", plain.substring(0, NaturalArticleVoice.splitPoint(plain)!!))
        assertNull(NaturalArticleVoice.splitPoint("unbreakable"))
        assertNull(NaturalArticleVoice.splitPoint("trailing, "))

        // A first half ends in the space it was cut after; splitting it again must still make progress.
        val sentence = "But it seems to me like our current equilibrium is that US midterm election prediction markets " +
            "are big enough (\$2.5 billion of volume on Kalshi) to provide real incentives for accurate predictions, " +
            "but not big enough to, like, swamp the actual elections."
        val pending = mutableListOf(sentence)
        var pieces = 0
        while (pending.isNotEmpty()) {
            val piece = pending.removeAt(pending.lastIndex)
            if (piece.length <= 20) continue
            val cut = NaturalArticleVoice.splitPoint(piece)!!
            val head = piece.substring(0, cut)
            val tail = piece.substring(cut)
            assertTrue(head.length < piece.length && tail.length < piece.length)
            assertTrue(head.any { it.isLetter() } && tail.any { it.isLetter() })
            pending += listOf(head, tail)
            pieces += 1
            assertTrue("Splitting never finished", pieces < 100)
        }
    }

    @Test fun noiseIsTheSameEveryRunAndUnitGaussian() {
        val a = SplitMix64(0x5EED).gaussians(100_001)
        assertArrayEquals(a, SplitMix64(0x5EED).gaussians(100_001), 0f)
        val mean = a.average()
        val variance = a.sumOf { (it - mean) * (it - mean) } / a.size
        assertEquals(0.0, mean, 0.02)
        assertEquals(1.0, variance, 0.02)
        assertTrue(generateSequence { SplitMix64(1).uniform() }.take(1).all { it in 0.0..<1.0 })
    }

    @Test fun wavesHoldTheSamplesAsSixteenBits() {
        val file = File.createTempFile("natural", ".wav")
        try {
            writeWave(file, floatArrayOf(0f, 1f, -1f, 2f), 24_000)
            val info = inspectWave(file)
            assertEquals(8, info.dataSize)
            assertEquals(48_000, info.bytesPerSecond)
        } finally { file.delete() }
    }

    @Test fun voicesAreNamedForTheirAccent() {
        assertEquals("Emma (British)", NaturalVoice("bf_emma").label)
        assertFalse(NaturalVoice("af_heart").isBritish)
    }

    /** "Up - down." phonemizes as "ʌp  dWn.": the dash says nothing but keeps its space, one phoneme. */
    @Test fun aSilentTokenTakesOnlyItsSpaceSoLaterWordsKeepTheirPlace() {
        val tokens = listOf(
            PhonemeToken("Up", "ʌp", " ", 0, 2), PhonemeToken("-", "", " ", 3, 4),
            PhonemeToken("down", "dWn", "", 5, 9), PhonemeToken(".", ".", "", 9, 10),
        )
        val words = NaturalVoiceEngine.words(tokens, List(10) { 2 })
        assertEquals(
            listOf(listOf(0, 2, 0, 3_000), listOf(5, 9, 4_200, 8_400)),
            words.map { listOf(it.characters.first, it.characters.last + 1, it.samples.first, it.samples.last + 1) },
        )
    }
}
