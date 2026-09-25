package com.henrydashwood.magpie.playback

import android.content.Context
import android.media.AudioManager
import android.os.VibrationEffect
import android.os.VibratorManager
import android.media.ToneGenerator
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/** A brief, quiet end marker on the media route, felt as well as heard (as on iOS); never speaks over the listener. */
class PlaybackFeedback(private val context: Context, private val scope: CoroutineScope) {
    // Lazy: the service creates this before its context is attached.
    private val vibrator by lazy { context.getSystemService(VibratorManager::class.java)?.defaultVibrator }
    private var tone: ToneGenerator? = null
    private var releaseJob: Job? = null

    fun finished() {
        close()
        // Two short pulses, like the iOS success haptic: noticeable in her hand, not startling.
        runCatching { vibrator?.vibrate(VibrationEffect.createWaveform(longArrayOf(0, 30, 90, 30), -1)) }
        // Missing audio must never prevent the service from finishing or pausing.
        val sound = runCatching { ToneGenerator(AudioManager.STREAM_MUSIC, 15) }.getOrNull() ?: return
        tone = sound
        runCatching { sound.startTone(ToneGenerator.TONE_PROP_ACK, 150) }
        releaseJob = scope.launch { delay(300); sound.release(); if (tone === sound) tone = null }
    }

    fun close() { releaseJob?.cancel(); releaseJob = null; tone?.release(); tone = null }
}
