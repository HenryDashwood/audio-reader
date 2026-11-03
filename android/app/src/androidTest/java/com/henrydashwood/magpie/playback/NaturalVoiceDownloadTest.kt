package com.henrydashwood.magpie.playback

import android.util.Log
import androidx.test.core.app.ApplicationProvider
import androidx.test.platform.app.InstrumentationRegistry
import com.henrydashwood.magpie.MagpieTestApplication
import java.io.File
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test

/**
 * Downloads the voice's asset pack, as Settings does. It needs an install from `make android-run-bundle`, Play's
 * local-testing mode, and is opt-in because it moves hundreds of megabytes:
 * `adb shell am instrument -w -e naturalVoiceDownload true -e class com.henrydashwood.magpie.playback.NaturalVoiceDownloadTest …`.
 */
class NaturalVoiceDownloadTest {
    private val app get() = ApplicationProvider.getApplicationContext<MagpieTestApplication>()

    @Test fun downloadsTheVoiceAndReadsFromIt() = runBlocking<Unit>(Dispatchers.Main) {
        assumeTrue(InstrumentationRegistry.getArguments().getString("naturalVoiceDownload") == "true")
        val download = NaturalVoiceDownload.get(app)
        download.refresh()
        val before = download.state.value
        Log.i(TAG, "before: $before")
        assertFalse("No asset pack in this install: use make android-run-bundle", before is NaturalVoiceDownload.State.Unavailable)
        if (before !is NaturalVoiceDownload.State.Installed) {
            download.download()
            val after = withTimeout(10 * 60_000) {
                download.state.first { it is NaturalVoiceDownload.State.Installed || it is NaturalVoiceDownload.State.Failed }
            }
            Log.i(TAG, "after: $after")
            assertTrue(after is NaturalVoiceDownload.State.Installed)
        }
        val folder = NaturalVoiceStore.folder(app)
        assertNotNull(folder)
        Log.i(TAG, "voice at $folder")
        val file = File(app.cacheDir, "natural-voice-download-test.wav")
        val text = "The downloaded voice reads this sentence."
        val frames = NaturalArticleVoice(app, folder!!, NaturalVoice("af_heart")).synthesize(TextChunk(text, 0, text.length), file)
        assertEquals(6, frames.size)
    }

    private companion object { const val TAG = "NaturalVoiceTest" }
}
