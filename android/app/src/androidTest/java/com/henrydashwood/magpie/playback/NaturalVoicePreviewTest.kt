package com.henrydashwood.magpie.playback

import android.os.SystemClock
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.media.MediaPlayer
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import com.henrydashwood.magpie.MainActivity
import com.henrydashwood.magpie.MagpieApplication
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.*
import org.junit.Test

class NaturalVoicePreviewTest {
    /** Uses native playback, but lets the test hold the first player's completion in flight. */
    private class SamplePlayer(val holdCompletion: Boolean) : MediaPlayer() {
        var starts = 0
        var releases = 0
        val released = CompletableDeferred<Unit>()
        private var startedAt = 0L
        val elapsedAtCompletion = CompletableDeferred<Long>()
        init {
            setOnErrorListener { _, what, extra ->
                elapsedAtCompletion.completeExceptionally(AssertionError("Playback error $what ($extra)"))
                true
            }
        }
        lateinit var completion: OnCompletionListener

        override fun setOnCompletionListener(listener: OnCompletionListener) {
            completion = listener
            super.setOnCompletionListener { finished ->
                val elapsed = SystemClock.elapsedRealtime() - startedAt
                if (!holdCompletion) listener.onCompletion(finished)
                elapsedAtCompletion.complete(elapsed)
            }
        }

        override fun start() {
            startedAt = SystemClock.elapsedRealtime()
            super.start()
            starts++
        }

        override fun release() {
            releases++
            super.release()
            released.complete(Unit)
        }
    }

    @Test fun lateFocusLossFromFirstPreviewLetsReplacementFinish() {
        val app = ApplicationProvider.getApplicationContext<MagpieApplication>()
        ActivityScenario.launch(MainActivity::class.java).use {
            runBlocking(Dispatchers.Main) {
                val listeners = mutableListOf<AudioManager.OnAudioFocusChangeListener>()
                val players = mutableListOf<SamplePlayer>()
                val preview = NaturalVoicePreview(app,
                    createPlayer = { SamplePlayer(false).also(players::add) },
                    buildFocusRequest = { attributes, listener ->
                        listeners.add(listener)
                        AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT)
                            .setAudioAttributes(attributes).setOnAudioFocusChangeListener(listener).build()
                    }) { _, file -> writeWave(file, FloatArray(16_000), 8_000) }
                try {
                    preview.play(NaturalVoice("bf_emma"))
                    preview.play(NaturalVoice("af_heart"))
                    val replacement = players[1]
                    assertEquals(1, players.first().releases)
                    assertTrue(replacement.isPlaying)
                    listeners.first().onAudioFocusChange(AudioManager.AUDIOFOCUS_LOSS_TRANSIENT)
                    assertEquals(0, replacement.releases)
                    val elapsed = withTimeout(10_000) { replacement.elapsedAtCompletion.await() }
                    assertTrue("Preview finished early at ${elapsed}ms", elapsed >= 1_900)
                    assertEquals(1, replacement.starts)
                    assertEquals(1, replacement.releases)
                } finally {
                    preview.stop()
                }
            }
        }
    }

    @Test fun replacementStopsPromptlyWhenAndroidTakesItsFocus() {
        val app = ApplicationProvider.getApplicationContext<MagpieApplication>()
        ActivityScenario.launch(MainActivity::class.java).use {
            runBlocking(Dispatchers.Main) {
                val manager = app.getSystemService(AudioManager::class.java)
                val competing = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT)
                    .setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build())
                    .setOnAudioFocusChangeListener {}.build()
                val players = mutableListOf<SamplePlayer>()
                val preview = NaturalVoicePreview(app, { SamplePlayer(false).also(players::add) }) { _, file ->
                    writeWave(file, FloatArray(40_000), 8_000)
                }
                try {
                    preview.play(NaturalVoice("bf_emma"))
                    preview.play(NaturalVoice("af_heart"))
                    val replacement = players[1]
                    assertTrue(replacement.isPlaying)
                    assertEquals(AudioManager.AUDIOFOCUS_REQUEST_GRANTED, manager.requestAudioFocus(competing))
                    withTimeout(1_000) { replacement.released.await() }
                    assertFalse(replacement.elapsedAtCompletion.isCompleted)
                    assertEquals(1, replacement.starts)
                    assertEquals(1, replacement.releases)
                } finally {
                    preview.stop()
                    manager.abandonAudioFocusRequest(competing)
                }
            }
        }
    }

    @Test fun lateCompletionFromReleasedPreviewLetsReplacementPlayOnceToItsEnd() {
        val app = ApplicationProvider.getApplicationContext<MagpieApplication>()
        ActivityScenario.launch(MainActivity::class.java).use {
            runBlocking(Dispatchers.Main) {
                val first = SamplePlayer(holdCompletion = true)
                val second = SamplePlayer(holdCompletion = false)
                val available = ArrayDeque(listOf(first, second))
                val a = NaturalVoice("bf_emma")
                val b = NaturalVoice("af_heart")
                val preview = NaturalVoicePreview(app, { available.removeFirst() }) { voice, file ->
                    writeWave(file, FloatArray(if (voice == a) 2_000 else 16_000), 8_000)
                }
                try {
                    preview.play(a)
                    withTimeout(10_000) { first.elapsedAtCompletion.await() }
                    preview.play(b)
                    assertEquals(1, first.releases)
                    assertTrue(second.isPlaying)
                    first.completion.onCompletion(first)
                    assertTrue(second.isPlaying)
                    assertEquals(2_000, second.duration)
                    val elapsed = withTimeout(10_000) { second.elapsedAtCompletion.await() }
                    assertTrue("Preview finished early at ${elapsed}ms", elapsed >= 1_900)
                    assertEquals(1, second.starts)
                    assertEquals(1, second.releases)
                } finally {
                    preview.stop()
                }
            }
        }
    }
}
