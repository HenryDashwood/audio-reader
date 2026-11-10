package com.henrydashwood.magpie

import android.content.ComponentName
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.Bundle
import android.os.SystemClock
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.media3.common.Player
import androidx.media3.session.MediaController
import androidx.media3.session.SessionCommand
import androidx.media3.session.SessionToken
import com.henrydashwood.magpie.playback.PlaybackService
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.util.concurrent.TimeUnit

/** Exercise Android's real focus callbacks through the same player as system controls. */
class PlaybackAudioFocusTest {
    @get:Rule val compose = createAndroidComposeRule<MainActivity>()

    private fun command(controller: MediaController, action: String, args: Bundle = Bundle.EMPTY) {
        val result = compose.runOnUiThread {
            controller.sendCustomCommand(SessionCommand(action, Bundle.EMPTY), args)
        }.get(10, TimeUnit.SECONDS)
        assertEquals(0, result.resultCode)
    }

    private fun withPlayback(check: (MediaController, AudioManager) -> Unit) {
        val context = compose.activity.applicationContext
        val controller = compose.runOnUiThread {
            MediaController.Builder(context, SessionToken(context,
                ComponentName(context, PlaybackService::class.java))).buildAsync()
        }.get(10, TimeUnit.SECONDS)
        try {
            command(controller, PlaybackService.DISMISS_PLAYER)
            command(controller, PlaybackService.PLAY_ITEM, Bundle().apply { putString("id", "welcome") })
            compose.runOnUiThread { controller.seekTo(0) }
            compose.waitUntil(15_000) { compose.runOnUiThread { controller.isPlaying } }
            check(controller, context.getSystemService(AudioManager::class.java))
        } finally {
            command(controller, PlaybackService.DISMISS_PLAYER)
            compose.runOnUiThread { controller.release() }
        }
    }

    private fun withCompetingFocus(manager: AudioManager, gain: Int, check: () -> Unit) {
        val request = AudioFocusRequest.Builder(gain)
            .setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA)
                .setContentType(AudioAttributes.CONTENT_TYPE_MOVIE).build())
            .setOnAudioFocusChangeListener {}.build()
        try {
            assertEquals(AudioManager.AUDIOFOCUS_REQUEST_GRANTED,
                compose.runOnUiThread { manager.requestAudioFocus(request) })
            check()
        } finally {
            compose.runOnUiThread { manager.abandonAudioFocusRequest(request) }
        }
    }

    private fun temporaryInterruption(gain: Int, pauseByUser: Boolean = false) = withPlayback { controller, manager ->
        withCompetingFocus(manager, gain) {
            compose.waitUntil(5_000) {
                compose.runOnUiThread {
                    !controller.isPlaying && controller.playWhenReady &&
                        controller.playbackSuppressionReason == Player.PLAYBACK_SUPPRESSION_REASON_TRANSIENT_AUDIO_FOCUS_LOSS
                }
            }
            if (pauseByUser) compose.runOnUiThread { controller.pause() }
        }
        if (pauseByUser) {
            // Give a delayed focus-gain callback time to arrive before checking intent.
            SystemClock.sleep(700)
            assertFalse(compose.runOnUiThread { controller.playWhenReady || controller.isPlaying })
        } else {
            compose.waitUntil(5_000) { compose.runOnUiThread { controller.isPlaying } }
            val position = compose.runOnUiThread { controller.currentPosition }
            compose.waitUntil(5_000) {
                compose.runOnUiThread { controller.isPlaying && controller.currentPosition > position + 500 }
            }
        }
    }

    @Test fun temporaryOtherAudioResumesWhenFocusReturns() =
        temporaryInterruption(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT)

    @Test fun speechPausesForADuckingRequestAndResumesWithoutMissingWords() =
        temporaryInterruption(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK)

    @Test fun manualPauseDuringAnInterruptionPreventsAutomaticResume() =
        temporaryInterruption(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT, pauseByUser = true)

    @Test fun anotherMediaAppTakingOverRequiresExplicitPlayToResume() = withPlayback { controller, manager ->
        withCompetingFocus(manager, AudioManager.AUDIOFOCUS_GAIN) {
            compose.waitUntil(5_000) {
                compose.runOnUiThread { !controller.playWhenReady && !controller.isPlaying }
            }
        }
        SystemClock.sleep(700)
        assertFalse(compose.runOnUiThread { controller.playWhenReady || controller.isPlaying })
        compose.runOnUiThread { controller.play() }
        compose.waitUntil(5_000) { compose.runOnUiThread { controller.isPlaying } }
    }
}
