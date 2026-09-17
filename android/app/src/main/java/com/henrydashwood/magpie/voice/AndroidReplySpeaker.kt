package com.henrydashwood.magpie.voice

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.Handler
import android.os.Looper
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import com.henrydashwood.magpie.playback.SpeechVoices
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/** Short-lived, offline-only spoken replies. Long-form item playback remains in Media3. */
class AndroidReplySpeaker(private val context: Context, private val selectedVoice: () -> String?) : VoiceOutput {
    private val speaker = SpokenReply { open() }
    override suspend fun speak(text: String) = withContext(Dispatchers.Main.immediate) { speaker.speak(text) }

    private suspend fun open(): ReplyEngine {
        val tts = SpeechVoices.open(context)
        val audio = context.getSystemService(AudioManager::class.java)
        val main = Handler(Looper.getMainLooper())
        var focus: AudioFocusRequest? = null
        var active: Pair<String, (String, String?) -> Unit>? = null
        var closed = false
        var interrupted = false
        fun finish(id: String?, error: String?) {
            main.post {
                val current = active
                if (!closed && current != null && current.first == id) {
                    active = null
                    current.second(current.first, error)
                }
            }
        }
        try {
            SpeechVoices.select(tts, selectedVoice())
            val attributes = AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_ASSISTANT)
                .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build()
            check(tts.setAudioAttributes(attributes) == TextToSpeech.SUCCESS) { "The speaking voice could not start." }
            check(tts.setSpeechRate(1f) == TextToSpeech.SUCCESS) { "The speaking voice could not start." }
            tts.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
                override fun onStart(utteranceId: String?) = Unit
                override fun onDone(utteranceId: String?) = finish(utteranceId, null)
                @Deprecated("Some speech engines use the original callback")
                override fun onError(utteranceId: String?) = finish(utteranceId, "The spoken reply could not finish. Please try again.")
                override fun onError(utteranceId: String?, errorCode: Int) = finish(utteranceId, "The spoken reply could not finish. Please try again.")
                override fun onStop(utteranceId: String?, interrupted: Boolean) = finish(utteranceId, "The spoken reply was interrupted.")
            })
            val request = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT)
                .setAudioAttributes(attributes).setOnAudioFocusChangeListener({ change ->
                    if (change < 0 && !closed) {
                        interrupted = true
                        active?.let { finish(it.first, "Audio was interrupted. Tap Listen when you are ready.") }
                        tts.stop()
                    }
                }, main).build()
            focus = request
            check(audio.requestAudioFocus(request) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED) {
                "Audio is in use. Try again when it is free."
            }
            return object : ReplyEngine {
                override val maxCharacters = TextToSpeech.getMaxSpeechInputLength()
                override fun speak(text: String, id: String, finished: (String, String?) -> Unit) {
                    check(!closed && !interrupted) { "The spoken reply was interrupted." }
                    active = id to finished
                    if (tts.speak(text, TextToSpeech.QUEUE_FLUSH, null, id) != TextToSpeech.SUCCESS)
                        throw VoiceFailure("The spoken reply could not start. Choose an installed offline voice in Settings.")
                }
                override fun close() {
                    closed = true; active = null
                    try { tts.stop(); tts.shutdown() } finally { audio.abandonAudioFocusRequest(request) }
                }
            }
        } catch (error: Throwable) {
            closed = true; active = null
            try { tts.shutdown() } finally { focus?.let { audio.abandonAudioFocusRequest(it) } }
            throw error
        }
    }
}
