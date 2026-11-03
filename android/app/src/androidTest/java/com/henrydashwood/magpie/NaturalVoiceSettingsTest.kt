package com.henrydashwood.magpie

import android.graphics.Bitmap
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.lifecycle.ViewModelProvider
import androidx.test.platform.app.InstrumentationRegistry
import com.henrydashwood.magpie.data.PreviewStore
import com.henrydashwood.magpie.playback.NaturalVoiceStore
import java.io.File
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test

/** Choosing who reads articles once the natural voice is here. Skipped unless it is: see NaturalVoiceTest. */
class NaturalVoiceSettingsTest {
    @get:Rule val compose = createAndroidComposeRule<MainActivity>()
    private fun model() = compose.runOnUiThread { ViewModelProvider(compose.activity)[MagpieModel::class.java] }

    @Test fun chooseANaturalSpeakerForArticles() {
        val context = compose.activity.applicationContext
        assumeTrue("The natural voice isn't on this device", NaturalVoiceStore.folder(context) != null)
        val store = PreviewStore(context)
        val previous = store.naturalVoice
        try {
            model()
            compose.onNodeWithText("Settings").performClick()
            compose.onNodeWithTag("settings-list").performScrollToNode(hasTestTag("natural-voice-setting"))
            compose.waitUntil(10_000) { compose.onAllNodesWithTag("natural-voice-setting").fetchSemanticsNodes().isNotEmpty() }
            compose.onNodeWithTag("natural-voice-setting").assertTextContains("Read articles with").performClick()
            compose.onNodeWithText("Emma (British)").performClick()
            compose.waitUntil(5_000) { compose.onAllNodesWithTag("natural-voice-list").fetchSemanticsNodes().isEmpty() }
            assertEquals("bf_emma", store.naturalVoice)
            assertEquals("natural:bf_emma", NaturalVoiceStore.articleVoice(context, store))
            compose.onNodeWithTag("natural-voice-setting").assertTextContains("Emma (British)")
            screenshot("natural-voice-settings")
            // The Google voice still speaks replies; only articles change
            assertEquals(store.voiceId, model().settings.value.voiceId)
        } finally {
            store.naturalVoice = previous
        }
    }

    private fun screenshot(name: String) {
        val image = InstrumentationRegistry.getInstrumentation().uiAutomation.takeScreenshot() ?: return
        val folder = compose.activity.getExternalFilesDir("screenshots") ?: return
        File(folder, "$name.png").outputStream().use { image.compress(Bitmap.CompressFormat.PNG, 100, it) }
    }
}
