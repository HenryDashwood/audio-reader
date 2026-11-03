package com.henrydashwood.magpie.playback

import android.util.Log
import androidx.test.core.app.ApplicationProvider
import com.henrydashwood.magpie.MagpieTestApplication
import com.henrydashwood.magpie.data.ContentKind
import com.henrydashwood.magpie.data.LibraryItem
import java.io.File
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Test

/**
 * The downloadable voice end to end on this device: text to phonemes, ONNX Runtime, LiteRT and back to a WAV with
 * word timings. It needs the voice on the device, so it is skipped unless a debug build's folder is there:
 * `adb push android-pack /sdcard/Android/data/com.henrydashwood.magpie.dev/files/NaturalVoice`.
 */
class NaturalVoiceTest {
    private val app get() = ApplicationProvider.getApplicationContext<MagpieTestApplication>()
    private lateinit var folder: File
    private val passage = listOf(
        "Mr. Lovelady and Mr. Calcraft testified that Oswald's rooming house stood near Clerkenwell.",
        "Speed comes from the voice itself, not from stretching the audio afterwards.",
        "Patreon and Vimeo both sent the Datalab team their figures on Thursday, from No. 10 Downing St. to St. Paul's, about 5 km away.",
    )

    @Before fun voiceIsHere() {
        val found = NaturalVoiceStore.folder(app)
        assumeTrue("The natural voice isn't on this device", found != null)
        folder = found!!
    }

    @Test fun readsSentencesWithWordTimings() = runBlocking<Unit>(Dispatchers.Default) {
        val voice = NaturalArticleVoice(app, folder, NaturalVoice("bf_emma"))
        for (pass in 1..2) {  // The first pass includes loading the models and preparing each body size
            for (sentence in passage) {
                val file = File(app.cacheDir, "natural-voice-test.wav")
                val started = System.nanoTime()
                val frames = voice.synthesize(TextChunk(sentence, 0, sentence.length), file)
                val seconds = (System.nanoTime() - started) / 1e9
                val wave = inspectWave(file)
                val audio = wave.dataSize / 2.0 / NaturalVoiceEngine.SAMPLE_RATE
                val words = frames.joinToString("|") { sentence.substring(it.startUtf16, it.endUtf16) }
                Log.i("NaturalVoiceTest", "pass $pass: %.1fs of audio in %.2fs, %.1fx real time; $words".format(audio, seconds, audio / seconds))
                assertTrue("Too short: $audio s", audio > 1.5)
                assertTrue(frames.size >= sentence.split(' ').size - 2)
                assertEquals(frames.sortedBy { it.frame }, frames)
                assertTrue(frames.all { it.frame < wave.dataSize / 2 && it.endUtf16 <= sentence.length })
            }
        }
        NaturalVoiceEngines.use(app, folder, NaturalVoice("bf_emma")) { Log.i("NaturalVoiceTest", "decoder on the ${it.accelerator}") }
    }

    /** Logs the process's memory as each body size is first used: short to long sentences, 64 to 512 frames. */
    @Test fun memoryAcrossEverySize() = runBlocking<Unit>(Dispatchers.Default) {
        val sentences = listOf(
            "Good morning.",
            "The river was quiet this morning.",
            "The river was quiet this morning, and the boats stayed tied to the wall.",
            "The river was quiet this morning, and the boats stayed tied to the wall until the tide began to turn.",
            "The river was quiet this morning, and the boats stayed tied to the wall until the tide began to turn, when the " +
                "first of them slipped out past the bridge.",
            "The river was quiet this morning, and the boats stayed tied to the wall until the tide began to turn, when the " +
                "first of them slipped out past the bridge and the gulls followed it down towards the sea, calling.",
        )
        val voice = NaturalArticleVoice(app, folder, NaturalVoice("bf_emma"))
        fun pss() = android.os.Debug.MemoryInfo().also(android.os.Debug::getMemoryInfo).totalPss / 1024
        val report = mutableListOf("before ${pss()} MB")
        for (sentence in sentences) {
            val file = File(app.cacheDir, "natural-voice-memory.wav")
            voice.synthesize(TextChunk(sentence, 0, sentence.length), file)
            report += "${inspectWave(file).dataSize / 2 / NaturalVoiceEngine.SAMPLE_RATE.toDouble()}s: ${pss()} MB"
        }
        Log.i("NaturalVoiceTest", "memory: ${report.joinToString()}")
    }

    @Test fun articlesReadWithTheChosenSpeaker() = runBlocking<Unit>(Dispatchers.Main) {
        val renderer = ArticleRenderer(app)
        try {
            val item = LibraryItem("natural", "Publication", "Natural voice", "", ContentKind.Article, "", passage.joinToString(" "), contentVersion = "v1")
            val audio = renderer.render(item, NaturalVoiceStore.PREFIX + "af_heart") { _, _ -> }
            assertEquals("natural:af_heart", audio.voiceName)
            assertTrue(audio.ranges(0).isNotEmpty())
        } finally { renderer.close() }
    }
}
