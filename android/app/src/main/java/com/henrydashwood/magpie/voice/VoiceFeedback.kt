package com.henrydashwood.magpie.voice

import android.content.Context
import android.media.AudioManager
import android.media.ToneGenerator
import android.os.Handler
import android.os.Looper
import android.os.VibrationEffect
import android.os.VibratorManager

/** The moments of a conversation that get a sound or a vibration, as on iOS (`Cue` in Feedback.swift). */
enum class VoiceCue { Opened, Acknowledged, Listening, Processing, Working, Failed, ListeningEnded }

/**
 * Short non-speech cues. She cannot see the screen change, so these are how she knows a tap
 * landed, when to start speaking, and that Magpie is still working. The "go ahead" cue is
 * felt as well as heard, so it lands in a noisy room or under TalkBack.
 */
class VoiceFeedback(context: Context) : (VoiceCue) -> Unit {
    private val vibrator = context.getSystemService(VibratorManager::class.java)?.defaultVibrator
    private val main = Handler(Looper.getMainLooper())

    override fun invoke(cue: VoiceCue) {
        when (cue) {
            // Lighter than the acknowledgement that follows, so the two are told apart.
            VoiceCue.Opened -> vibrate(VibrationEffect.EFFECT_TICK)
            VoiceCue.Acknowledged -> { vibrate(VibrationEffect.EFFECT_CLICK); tone(ToneGenerator.TONE_PROP_BEEP) }
            VoiceCue.Listening -> { vibrate(VibrationEffect.EFFECT_HEAVY_CLICK); tone(ToneGenerator.TONE_PROP_ACK) }
            VoiceCue.Processing -> { vibrate(VibrationEffect.EFFECT_CLICK); tone(ToneGenerator.TONE_PROP_BEEP) }
            VoiceCue.Working -> tone(ToneGenerator.TONE_PROP_BEEP)
            // Three pulses, like the iOS error haptic, so it is not mistaken for the end-of-item pair.
            VoiceCue.Failed -> runCatching { vibrator?.vibrate(VibrationEffect.createWaveform(longArrayOf(0, 30, 70, 30, 70, 30), -1)) }
            VoiceCue.ListeningEnded -> { vibrate(VibrationEffect.EFFECT_TICK); tone(ToneGenerator.TONE_PROP_BEEP) }
        }
    }

    // A missing tone or vibrator must never interrupt the conversation itself.
    private fun tone(type: Int) {
        val generator = runCatching { ToneGenerator(AudioManager.STREAM_MUSIC, 60) }.getOrNull() ?: return
        runCatching { generator.startTone(type, 150) }
        main.postDelayed({ generator.release() }, 400)
    }

    private fun vibrate(effect: Int) { runCatching { vibrator?.vibrate(VibrationEffect.createPredefined(effect)) } }
}
