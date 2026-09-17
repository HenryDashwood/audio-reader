package com.henrydashwood.magpie

import android.Manifest
import android.content.ContextWrapper
import android.content.pm.PackageManager
import android.os.Bundle
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import com.henrydashwood.magpie.playback.SpeechVoices
import com.henrydashwood.magpie.voice.*
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import java.util.Locale

class VoiceAudioTest {
    @get:Rule val compose = createAndroidComposeRule<MainActivity>()

    @Test fun recognitionIntentAndCallbacksKeepFinalTextSeparateFromCaptions() {
        val intent = AndroidSpeechInput.intent(Locale.UK)
        assertEquals(RecognizerIntent.ACTION_RECOGNIZE_SPEECH, intent.action)
        assertEquals("en-GB", intent.getStringExtra(RecognizerIntent.EXTRA_LANGUAGE))
        assertTrue(intent.getBooleanExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, false))
        assertTrue(intent.getBooleanExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, false))
        val events = mutableListOf<RecognitionEvent>()
        val listener = AndroidSpeechInput.Listener(events::add)
        fun result(text: String) = Bundle().apply { putStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION, arrayListOf(text, "Other candidate")) }
        listener.onReadyForSpeech(null); listener.onPartialResults(result("Play"))
        listener.onEndOfSpeech(); listener.onResults(result("Pause"))
        assertEquals(listOf(RecognitionEvent.Ready, RecognitionEvent.Partial("Play"), RecognitionEvent.End, RecognitionEvent.Final("Pause")), events)
        listener.onError(SpeechRecognizer.ERROR_LANGUAGE_UNAVAILABLE)
        assertTrue((events.last() as RecognitionEvent.Failed).message.contains("not downloaded"))
        listener.onError(SpeechRecognizer.ERROR_NO_MATCH); assertEquals(RecognitionEvent.Silence, events.last())
    }

    @Test fun missingPermissionFailsBeforeCreatingOrOpeningTheMicrophone() = runBlocking {
        val context = object : ContextWrapper(compose.activity) {
            override fun checkSelfPermission(permission: String): Int =
                if (permission == Manifest.permission.RECORD_AUDIO) PackageManager.PERMISSION_DENIED else super.checkSelfPermission(permission)
        }
        var ready = false
        val failure = runCatching { AndroidSpeechInput(context).listen(onReady = { ready = true }) }.exceptionOrNull()
        assertTrue(failure is VoiceFailure); assertTrue(failure!!.message!!.contains("microphone access")); assertFalse(ready)
    }

    @Test fun nativeCapabilityCheckFinishesWithoutOpeningTheMicrophone() = runBlocking {
        val result = withTimeout(15_000) { AndroidSpeechInput(compose.activity).availability() }
        assertTrue(result in RecognitionAvailability.entries)
        // A missing model is a supported result, not a successful recognition claim.
    }

    @Test fun installedOfflineVoiceActuallyFinishesASpokenReply() = runBlocking {
        compose.waitForIdle()
        val hasVoice = withContext(Dispatchers.Main) {
            val engine = SpeechVoices.open(compose.activity)
            try { SpeechVoices.installed(engine).any { it.locale.language == "en" } }
            finally { engine.shutdown() }
        }
        assumeTrue("No installed English offline voice; spoken-audio acceptance skipped", hasVoice)
        val store = com.henrydashwood.magpie.data.PreviewStore(compose.activity)
        val kind = com.henrydashwood.magpie.data.ContentKind.Article
        val previous = store.speed(kind)
        try {
            val speaker = AndroidReplySpeaker(compose.activity) { null }
            store.saveSpeed(kind, 1.75f)
            withTimeout(45_000) { speaker.speak("Magpie is ready. What would you like to listen to?") }
            store.saveSpeed(kind, .75f)
            withTimeout(45_000) { speaker.speak("Your new reading speed also applies to this reply.") }
        } finally { store.saveSpeed(kind, previous) }
    }

    @Test fun missingSelectedVoiceNeverFallsBackToAnotherVoice() = runBlocking {
        val failure = runCatching {
            withTimeout(20_000) { AndroidReplySpeaker(compose.activity) { "magpie-test-voice-not-installed" }.speak("Do not speak using another voice.") }
        }.exceptionOrNull()
        assertNotNull(failure)
        assertTrue(failure!!.message.orEmpty().contains("selected voice is no longer installed"))
    }
}
