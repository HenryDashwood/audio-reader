package com.henrydashwood.magpie.voice

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.speech.RecognitionListener
import android.speech.ModelDownloadListener
import android.speech.RecognitionSupport
import android.speech.RecognitionSupportCallback
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import java.util.Locale

enum class RecognitionAvailability { Ready, DownloadNeeded, Downloading, Unavailable, Unknown }

/** Always uses the on-device factory, including when an older engine cannot report its models. */
class AndroidSpeechInput(private val context: Context, val locale: Locale = Locale.UK) {
    private val capture = SpeechCapture()

    suspend fun availability(): RecognitionAvailability = withContext(Dispatchers.Main.immediate) {
        if (!SpeechRecognizer.isOnDeviceRecognitionAvailable(context)) return@withContext RecognitionAvailability.Unavailable
        if (Build.VERSION.SDK_INT < 33) return@withContext RecognitionAvailability.Unknown
        val engine = SpeechRecognizer.createOnDeviceSpeechRecognizer(context)
        try {
            engine.setRecognitionListener(Listener {})
            val result = CompletableDeferred<RecognitionAvailability>()
            engine.checkRecognitionSupport(intent(locale), context.mainExecutor, object : RecognitionSupportCallback {
                override fun onSupportResult(support: RecognitionSupport) {
                    fun List<String>.includesLocale() = any { it.equals(locale.toLanguageTag(), ignoreCase = true) }
                    result.complete(when {
                        support.installedOnDeviceLanguages.includesLocale() -> RecognitionAvailability.Ready
                        support.pendingOnDeviceLanguages.includesLocale() -> RecognitionAvailability.Downloading
                        support.supportedOnDeviceLanguages.includesLocale() -> RecognitionAvailability.DownloadNeeded
                        else -> RecognitionAvailability.Unavailable
                    })
                }
                override fun onError(error: Int) { result.complete(when (error) {
                    SpeechRecognizer.ERROR_LANGUAGE_NOT_SUPPORTED -> RecognitionAvailability.Unavailable
                    SpeechRecognizer.ERROR_LANGUAGE_UNAVAILABLE -> RecognitionAvailability.DownloadNeeded
                    else -> RecognitionAvailability.Unknown
                }) }
            })
            withTimeoutOrNull(10_000) { result.await() } ?: RecognitionAvailability.Unknown
        } finally { engine.destroy() }
    }

    /** User-initiated only. Requesting a download is not evidence that a model is ready. */
    suspend fun requestModelDownload() = withContext(Dispatchers.Main.immediate) {
        if (Build.VERSION.SDK_INT < 33 || !SpeechRecognizer.isOnDeviceRecognitionAvailable(context))
            throw VoiceFailure("Install an offline speech recognition language in Android settings, then try again.")
        val engine = SpeechRecognizer.createOnDeviceSpeechRecognizer(context)
        try {
            engine.setRecognitionListener(Listener {})
            val result = CompletableDeferred<Unit>()
            if (Build.VERSION.SDK_INT >= 34) {
                engine.triggerModelDownload(intent(locale), context.mainExecutor, object : ModelDownloadListener {
                    override fun onProgress(completedPercent: Int) = Unit
                    override fun onSuccess() { result.complete(Unit) }
                    override fun onScheduled() { result.complete(Unit) }
                    override fun onError(error: Int) { result.completeExceptionally(VoiceFailure("The recognition language could not download. Try again in Android speech settings.")) }
                })
            } else {
                engine.triggerModelDownload(intent(locale))
                // Wait for the queued request to reach the service before destroying its connection.
                engine.checkRecognitionSupport(intent(locale), context.mainExecutor, object : RecognitionSupportCallback {
                    override fun onSupportResult(support: RecognitionSupport) { result.complete(Unit) }
                    override fun onError(error: Int) { result.complete(Unit) }
                })
            }
            withTimeoutOrNull(300_000) { result.await(); true }
                ?: throw VoiceFailure("The recognition download is taking longer than expected. Check its status in Android speech settings.")
        } finally { engine.destroy() }
    }

    suspend fun listen(firstWordsMs: Long = 8_000, onReady: () -> Unit = {}, onPartial: (String) -> Unit = {}): String? =
        withContext(Dispatchers.Main.immediate) {
            if (context.checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED)
                throw VoiceFailure("Allow microphone access to speak to Magpie.")
            if (!SpeechRecognizer.isOnDeviceRecognitionAvailable(context))
                throw VoiceFailure("On-device speech recognition is unavailable. Install an offline recognition service to use the microphone.")
            val engine = SpeechRecognizer.createOnDeviceSpeechRecognizer(context)
            capture.listen(object : RecognitionEngine {
                override fun start(emit: (RecognitionEvent) -> Unit) {
                    engine.setRecognitionListener(Listener(emit))
                    engine.startListening(intent(locale))
                }
                override fun finish() { engine.stopListening() }
                override fun close() { try { engine.cancel() } finally { engine.destroy() } }
            }, firstWordsMs, onReady, onPartial)
        }

    /** Call on the main thread. Cancellation of listen() immediately closes the native recognizer. */
    fun finish() = capture.finish()

    internal class Listener(private val emit: (RecognitionEvent) -> Unit) : RecognitionListener {
        override fun onReadyForSpeech(params: Bundle?) = emit(RecognitionEvent.Ready)
        override fun onBeginningOfSpeech() = emit(RecognitionEvent.Beginning)
        override fun onEndOfSpeech() = emit(RecognitionEvent.End)
        override fun onPartialResults(partialResults: Bundle?) = emit(RecognitionEvent.Partial(text(partialResults)))
        override fun onResults(results: Bundle?) = emit(RecognitionEvent.Final(text(results)))
        override fun onError(error: Int) = emit(when (error) {
            SpeechRecognizer.ERROR_SPEECH_TIMEOUT, SpeechRecognizer.ERROR_NO_MATCH -> RecognitionEvent.Silence
            SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS -> RecognitionEvent.Failed("Allow microphone access to speak to Magpie.")
            SpeechRecognizer.ERROR_LANGUAGE_UNAVAILABLE -> RecognitionEvent.Failed("The offline recognition language is not downloaded. Download it, then try again.")
            SpeechRecognizer.ERROR_LANGUAGE_NOT_SUPPORTED -> RecognitionEvent.Failed("The installed speech service does not support this recognition language offline.")
            SpeechRecognizer.ERROR_RECOGNIZER_BUSY -> RecognitionEvent.Failed("The microphone is in use. Try again when it is free.")
            else -> RecognitionEvent.Failed("Speech recognition could not finish. Please try again.")
        })
        override fun onRmsChanged(rmsdB: Float) = Unit
        override fun onBufferReceived(buffer: ByteArray?) = Unit // Never retain microphone audio.
        override fun onEvent(eventType: Int, params: Bundle?) = Unit
        private fun text(bundle: Bundle?) = bundle?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull().orEmpty()
    }

    companion object {
        internal fun intent(locale: Locale) = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            putExtra(RecognizerIntent.EXTRA_LANGUAGE, locale.toLanguageTag())
            putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
            putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 1)
            putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, true)
        }
    }
}
