package com.henrydashwood.magpie.playback

import android.media.AudioManager
import android.media.ToneGenerator
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/** A brief, quiet end marker on the media route; never speaks over the listener. */
class SleepTimerFeedback(private val scope: CoroutineScope) {
    private var tone: ToneGenerator? = null
    private var releaseJob: Job? = null

    fun finished() {
        close()
        // A missing audio device must never stop the timer from pausing playback.
        val sound = runCatching { ToneGenerator(AudioManager.STREAM_MUSIC, 15) }.getOrNull() ?: return
        tone = sound
        runCatching { sound.startTone(ToneGenerator.TONE_PROP_ACK, 150) }
        releaseJob = scope.launch { delay(300); sound.release(); if (tone === sound) tone = null }
    }

    fun close() { releaseJob?.cancel(); releaseJob = null; tone?.release(); tone = null }
}
