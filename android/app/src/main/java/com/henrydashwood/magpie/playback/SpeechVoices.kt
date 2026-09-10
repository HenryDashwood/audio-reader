package com.henrydashwood.magpie.playback

import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.speech.tts.TextToSpeech
import android.speech.tts.Voice
import java.util.Locale
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.withTimeout

/** Both the picker and renderer use the same installed, offline-only voice policy. */
object SpeechVoices {
    const val ENGINE = "com.google.android.tts"

    suspend fun open(context: Context): TextToSpeech {
        val services = context.packageManager.queryIntentServices(
            Intent(TextToSpeech.Engine.INTENT_ACTION_TTS_SERVICE).setPackage(ENGINE), 0,
        )
        check(services.isNotEmpty()) { "Install Speech Recognition & Synthesis from Google to listen to articles. The sample recording still works." }
        val ready = CompletableDeferred<Int>()
        val tts = TextToSpeech(context, { status -> Handler(Looper.getMainLooper()).post { ready.complete(status) } }, ENGINE)
        try {
            check(withTimeout(15_000) { ready.await() } == TextToSpeech.SUCCESS) { "The reading voice could not start. Please try again." }
            return tts
        } catch (error: Throwable) {
            tts.shutdown()
            throw error
        }
    }

    fun installed(tts: TextToSpeech): List<Voice> = tts.voices.orEmpty().filter {
        !it.isNetworkConnectionRequired && TextToSpeech.Engine.KEY_FEATURE_NOT_INSTALLED !in it.features.orEmpty()
    }.sortedWith(compareByDescending<Voice> { it.locale.language == Locale.UK.language }
        .thenByDescending { it.locale.country == Locale.UK.country }
        .thenBy { it.locale.toLanguageTag() }.thenByDescending { it.quality }.thenBy { it.name })

    fun select(tts: TextToSpeech, selected: String?): Voice {
        val available = installed(tts)
        val voice = if (selected != null) available.find { it.name == selected }
            ?: error("Your selected voice is no longer installed. Choose another voice in Settings.")
        else available.firstOrNull { it.locale.language == Locale.UK.language }
            ?: error("Download an English offline voice in Android's text-to-speech settings, then try again.")
        check(tts.setVoice(voice) == TextToSpeech.SUCCESS) { "The selected reading voice is unavailable." }
        return voice
    }
}
