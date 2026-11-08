package com.henrydashwood.magpie

import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createEmptyComposeRule
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import com.google.android.gms.tasks.Tasks
import com.google.android.play.core.assetpacks.*
import com.google.android.play.core.assetpacks.model.AssetPackStatus as Status
import com.henrydashwood.magpie.playback.NaturalVoiceDownload
import com.henrydashwood.magpie.playback.NaturalVoiceStore
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test

class NaturalVoiceDownloadRestartTest {
    @get:Rule val compose = createEmptyComposeRule()

    /** Play's current state can differ from the payload of an already queued broadcast. */
    private class PackManager(app: MagpieTestApplication) : AssetPackManager by AssetPackManagerFactory.getInstance(app) {
        val pack = NaturalVoiceStore.PACK
        lateinit var listener: AssetPackStateUpdateListener
        var attempts = 0
        val cancelled = mutableListOf<Int>()
        private var current = update(Status.NOT_INSTALLED)

        fun update(status: Int, bytes: Long = 0) = object : AssetPackState() {
            override fun name() = pack
            override fun status() = status
            override fun bytesDownloaded() = bytes
            override fun totalBytesToDownload() = 100L
            override fun transferProgressPercentage() = 0
            override fun errorCode() = 0
            override fun updateAvailability() = 0
            override fun installedVersionTag() = ""
            override fun availableVersionTag() = ""
        }

        private fun snapshot(): AssetPackStates {
            val states = mapOf(pack to current)
            return object : AssetPackStates() {
                override fun packStates() = states
                override fun totalBytes() = 100L
            }
        }

        override fun registerListener(listener: AssetPackStateUpdateListener) { this.listener = listener }
        override fun getPackStates(packNames: List<String>) = Tasks.forResult(snapshot())
        override fun fetch(packNames: List<String>): com.google.android.gms.tasks.Task<AssetPackStates> {
            assertEquals(listOf(pack), packNames)
            attempts++
            current = update(Status.PENDING)
            return Tasks.forResult(snapshot())
        }
        override fun cancel(packNames: List<String>): AssetPackStates {
            assertEquals(listOf(pack), packNames)
            cancelled.add(attempts)
            publish(Status.CANCELED)
            return snapshot()
        }

        fun publish(status: Int, bytes: Long = 0) {
            current = update(status, bytes)
            listener.onStateUpdate(current)
        }
    }

    @Test fun lateProgressAfterRestart() = checkRestart(Status.DOWNLOADING, 90)
    @Test fun lateWifiWaitAfterRestart() = checkRestart(Status.WAITING_FOR_WIFI, 0)

    private fun visible(label: String): SemanticsNodeInteraction {
        val match = hasText(label, substring = true)
        compose.onNodeWithTag("settings-list").performScrollToNode(match)
        return compose.onNode(match).assertIsDisplayed()
    }

    private fun checkRestart(staleStatus: Int, staleBytes: Long) {
        val app = ApplicationProvider.getApplicationContext<MagpieTestApplication>()
        val manager = PackManager(app)
        app.naturalDownloadOverride = NaturalVoiceDownload(app, manager, installedFolder = { null })
        try {
            ActivityScenario.launch(MainActivity::class.java).use {
                compose.onNodeWithText("Settings").performClick()
                visible("Download natural voice (").performClick()
                val queued = manager.update(staleStatus, staleBytes)
                visible("Cancel download").performClick()
                visible("Download natural voice (").performClick()
                compose.runOnUiThread { manager.publish(Status.DOWNLOADING, 10) }
                visible("9%")
                compose.runOnUiThread { manager.listener.onStateUpdate(queued) }
                visible("9%")

                compose.onNodeWithText("Following").performClick()
                compose.onNodeWithText("Settings").performClick()
                visible("9%")
                // The same kinds of update must still work for the current download.
                compose.runOnUiThread { manager.publish(staleStatus, staleBytes) }
                visible(if (staleStatus == Status.DOWNLOADING) "81%" else "The download will start on Wi-Fi.")
                visible("Cancel download").performClick()
                visible("Download natural voice (")
                assertEquals(listOf(1, 2), manager.cancelled)
            }
        } finally {
            app.naturalDownloadOverride = null
        }
    }
}
