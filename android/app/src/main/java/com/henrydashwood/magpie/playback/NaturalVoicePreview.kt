package com.henrydashwood.magpie.playback

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.media.MediaPlayer
import java.io.File

/** Lets her hear a natural speaker on choosing it. The first sentence takes a moment while the voice loads. */
internal class NaturalVoicePreview(
    private val context: Context,
    private val createPlayer: () -> MediaPlayer = { MediaPlayer() },
    private val buildFocusRequest: (AudioAttributes, AudioManager.OnAudioFocusChangeListener) -> AudioFocusRequest =
        { attributes, listener -> AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT)
            .setAudioAttributes(attributes).setOnAudioFocusChangeListener(listener).build() },
    private val renderSample: suspend (NaturalVoice, File) -> Unit = { voice, file ->
        val folder = NaturalVoiceStore.folder(context) ?: error("The natural voice isn't on this phone. Download it again.")
        val text = "This voice will read your articles."
        NaturalArticleVoice(context, folder, voice).synthesize(TextChunk(text, 0, text.length), file)
    },
) {
    private val audioManager = context.getSystemService(AudioManager::class.java)
    private var player: MediaPlayer? = null
    private var focus: AudioFocusRequest? = null

    /** Renders and plays the sample sentence; throws with a message she can act on. */
    suspend fun play(voice: NaturalVoice) {
        stop()
        val file = File(context.cacheDir, "natural-voice-preview.wav")
        renderSample(voice, file)
        val attributes = AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA).setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build()
        lateinit var request: AudioFocusRequest
        request = buildFocusRequest(attributes) { change ->
            if (change < 0 && focus === request) stop()
        }
        check(audioManager.requestAudioFocus(request) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED) { "Audio is in use. Try the voice again when it is free." }
        focus = request
        player = createPlayer().apply {
            setAudioAttributes(attributes)
            setDataSource(file.path)
            setOnCompletionListener { finished ->
                if (finished === player) this@NaturalVoicePreview.stop()
            }
            prepare()
            start()
        }
    }

    fun stop() {
        player?.release()
        player = null
        focus?.let { audioManager.abandonAudioFocusRequest(it) }
        focus = null
    }
}
