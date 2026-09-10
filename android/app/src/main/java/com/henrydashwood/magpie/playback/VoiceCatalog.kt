package com.henrydashwood.magpie.playback

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.Handler
import android.os.Looper
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import java.util.Locale
import java.util.UUID
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update

data class VoiceOption(val id: String, val label: String, val quality: String)
data class VoiceCatalogState(val loading: Boolean = false, val voices: List<VoiceOption> = emptyList(), val error: String? = null, val previewing: Boolean = false)

/** A separate, short-lived TTS client for choosing voices; article playback remains in Media3. */
class VoiceCatalog(private val context: Context) {
    private val mutableState = MutableStateFlow(VoiceCatalogState())
    val state = mutableState.asStateFlow()
    private var engine: TextToSpeech? = null
    private val audioManager = context.getSystemService(AudioManager::class.java)
    private val main = Handler(Looper.getMainLooper())
    private var focus: AudioFocusRequest? = null
    private var utterance: String? = null

    suspend fun refresh() {
        close()
        mutableState.value = VoiceCatalogState(loading = true)
        try {
            val tts = SpeechVoices.open(context)
            engine = tts
            val options = withContext(Dispatchers.IO) {
                val counts = mutableMapOf<String, Int>()
                SpeechVoices.installed(tts).map { voice ->
                    val tag = voice.locale.toLanguageTag()
                    val number = (counts[tag] ?: 0) + 1
                    counts[tag] = number
                    VoiceOption(voice.name, "${voice.locale.getDisplayName(Locale.getDefault())} · Voice $number",
                        if (voice.quality >= android.speech.tts.Voice.QUALITY_HIGH) "High quality · Offline" else "Offline")
                }
            }
            mutableState.value = VoiceCatalogState(voices = options, error = if (options.isEmpty()) "No offline speech voice is installed. Download a voice in Android's text-to-speech settings." else null)
        } catch (_: TimeoutCancellationException) {
            mutableState.value = VoiceCatalogState(error = "The voice service took too long to respond. Try refreshing voices.")
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Exception) {
            mutableState.value = VoiceCatalogState(error = error.message ?: "The voices could not be loaded. Try again.")
        }
    }

    fun preview(selected: String?, speed: Float) {
        stop()
        val tts = engine ?: return
        try {
            SpeechVoices.select(tts, selected)
            val attributes = AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA).setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build()
            tts.setAudioAttributes(attributes)
            val request = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT)
                .setAudioAttributes(attributes).setOnAudioFocusChangeListener({ change ->
                    if (change < 0) stop()
                }, main).build()
            check(audioManager.requestAudioFocus(request) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED) { "Audio is in use. Try the voice again when it is free." }
            focus = request
            val id = UUID.randomUUID().toString()
            utterance = id
            tts.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
                override fun onStart(utteranceId: String?) = Unit
                override fun onDone(utteranceId: String?) { finish(utteranceId, null) }
                @Deprecated("Android calls either overload depending on the engine")
                override fun onError(utteranceId: String?) { finish(utteranceId, "The voice preview could not play. Try another voice.") }
                override fun onError(utteranceId: String?, errorCode: Int) { finish(utteranceId, "The voice preview could not play. Try another voice.") }
                private fun finish(id: String?, error: String?) {
                    main.post {
                        if (utterance == id) { stop(); mutableState.update { it.copy(error = error) } }
                    }
                }
            })
            tts.setSpeechRate(speed)
            mutableState.update { it.copy(previewing = true, error = null) }
            check(tts.speak("This voice will read your articles.", TextToSpeech.QUEUE_FLUSH, null, id) == TextToSpeech.SUCCESS) { "The voice preview could not start. Try another voice." }
            main.postDelayed({
                if (utterance == id) { stop(); mutableState.update { it.copy(error = "The voice preview took too long. Try another voice.") } }
            }, 20_000)
        } catch (error: Exception) {
            stop()
            mutableState.update { it.copy(error = error.message) }
        }
    }

    fun stop() {
        utterance = null
        engine?.stop()
        focus?.let { audioManager.abandonAudioFocusRequest(it) }
        focus = null
        mutableState.update { it.copy(previewing = false) }
    }

    fun close() {
        stop()
        engine?.shutdown()
        engine = null
    }
}
