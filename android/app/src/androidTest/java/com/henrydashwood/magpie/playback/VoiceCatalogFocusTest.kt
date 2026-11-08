package com.henrydashwood.magpie.playback

import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.speech.tts.UtteranceProgressListener
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import com.henrydashwood.magpie.MagpieApplication
import com.henrydashwood.magpie.MainActivity
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test

class VoiceCatalogFocusTest {
    private enum class Speech { Started, Finished, Interrupted, Failed }
    private data class Event(val id: String?, val speech: Speech)

    private class Previews(val manager: AudioManager) {
        val focusListeners = mutableListOf<AudioManager.OnAudioFocusChangeListener>()
        private val events = Channel<Event>(Channel.UNLIMITED)

        fun observe(listener: UtteranceProgressListener) = object : UtteranceProgressListener() {
            override fun onStart(id: String?) {
                listener.onStart(id)
                events.trySend(Event(id, Speech.Started))
            }
            override fun onDone(id: String?) {
                listener.onDone(id)
                events.trySend(Event(id, Speech.Finished))
            }
            override fun onStop(id: String?, interrupted: Boolean) {
                listener.onStop(id, interrupted)
                events.trySend(Event(id, Speech.Interrupted))
            }
            @Deprecated("Android TTS also calls the single-argument overload")
            override fun onError(id: String?) = onError(id, android.speech.tts.TextToSpeech.ERROR)
            override fun onError(id: String?, errorCode: Int) {
                listener.onError(id, errorCode)
                events.trySend(Event(id, Speech.Failed))
            }
        }

        suspend fun nextMatching(matches: (Event) -> Boolean): Event {
            var event = events.receive()
            while (!matches(event)) event = events.receive()
            return event
        }
    }

    private fun withReplacement(check: suspend Previews.(VoiceCatalog, String) -> Unit) {
        val app = ApplicationProvider.getApplicationContext<MagpieApplication>()
        ActivityScenario.launch(MainActivity::class.java).use {
            runBlocking(Dispatchers.Main) {
                val previews = Previews(app.getSystemService(AudioManager::class.java))
                val catalog = VoiceCatalog(app,
                    buildFocusRequest = { attributes, listener ->
                        previews.focusListeners.add(listener)
                        googleVoiceFocusRequest(attributes, listener)
                    },
                    setProgressListener = { tts, listener -> tts.setOnUtteranceProgressListener(previews.observe(listener)) })
                try {
                    catalog.refresh()
                    val voices = catalog.state.value.voices
                    assumeTrue("Requires two installed offline Google voices", voices.size >= 2)
                    withTimeout(15_000) {
                        catalog.preview(voices[0].id, 1f)
                        val a = previews.nextMatching { it.speech == Speech.Started }.id
                        catalog.preview(voices[1].id, 1f)
                        val b = previews.nextMatching { it.id != a && it.speech == Speech.Started }
                        previews.check(catalog, requireNotNull(b.id))
                    }
                } finally { catalog.close() }
            }
        }
    }

    @Test fun delayedFocusLossFromFirstVoiceLetsReplacementFinishOnce() = withReplacement { catalog, b ->
        focusListeners.first().onAudioFocusChange(AudioManager.AUDIOFOCUS_LOSS_TRANSIENT)
        assertTrue(catalog.state.value.previewing)
        // A second start, interruption or error for B would fail this assertion.
        assertEquals(Speech.Finished, nextMatching { it.id == b }.speech)
        assertNull(catalog.state.first { !it.previewing }.error)
    }

    @Test fun currentVoiceStopsPromptlyWhenAndroidTransfersFocus() = withReplacement { catalog, b ->
        val competing = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT)
            .setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA)
                .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build())
            .setOnAudioFocusChangeListener {}.build()
        try {
            withTimeout(1_000) {
                assertEquals(AudioManager.AUDIOFOCUS_REQUEST_GRANTED, manager.requestAudioFocus(competing))
                assertEquals(Speech.Interrupted, nextMatching { it.id == b }.speech)
                assertNull(catalog.state.first { !it.previewing }.error)
            }
        } finally { manager.abandonAudioFocusRequest(competing) }
    }
}
