package com.henrydashwood.magpie

import android.content.Context
import android.content.ContextWrapper
import android.content.SharedPreferences
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.lifecycle.ViewModelProvider
import com.henrydashwood.magpie.data.ContentKind
import com.henrydashwood.magpie.data.PreviewStore
import com.henrydashwood.magpie.playback.PlaybackStatus
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

class SettingsTest {
    @get:Rule val compose = createAndroidComposeRule<MainActivity>()
    private fun model() = compose.runOnUiThread { ViewModelProvider(compose.activity)[MagpieModel::class.java] }

    @Test fun legacySpeedMigratesWithoutCouplingNewPreferences() {
        val context = compose.activity.applicationContext
        val preferences = context.getSharedPreferences("settings_migration_test", Context.MODE_PRIVATE)
        preferences.edit().clear().putFloat("speed", 1.25f).commit()
        val isolated = object : ContextWrapper(context) {
            override fun getSharedPreferences(name: String?, mode: Int): SharedPreferences = preferences
        }
        val store = PreviewStore(isolated)
        try {
            assertEquals(1.25f, store.speed(ContentKind.Podcast))
            assertEquals(1.25f, store.speed(ContentKind.Article))
            store.saveSpeed(ContentKind.Podcast, 1.75f)
            assertEquals(1.25f, store.speed(ContentKind.Article))
            store.saveSpeed(ContentKind.Article, 0.75f)
            val reopened = PreviewStore(isolated)
            assertEquals(1.75f, reopened.speed(ContentKind.Podcast))
            assertEquals(0.75f, reopened.speed(ContentKind.Article))
        } finally { preferences.edit().clear().commit() }
    }

    @Test fun separateSpeedsPersistAndOnlyChangeTheMatchingPlayback() {
        var model = model()
        val previous = model.settings.value
        try {
            compose.waitUntil(10_000) { model.player.value.connected }
            compose.runOnUiThread { model.play(model.library.first { it.kind == ContentKind.Podcast }) }
            compose.waitUntil(15_000) { model.player.value.playing }
            compose.onNodeWithText("Settings").performClick()
            compose.onNodeWithTag("speed-Podcasts").performClick()
            compose.onNode(hasText("1.5×") and hasAnyAncestor(isDialog())).performClick()
            compose.waitUntil(5_000) { model.player.value.speed == 1.5f }
            compose.onNodeWithTag("speed-Articles").performClick()
            compose.onNode(hasText("0.75×") and hasAnyAncestor(isDialog())).performClick()
            assertEquals(1.5f, model.player.value.speed)
            assertEquals(0.75f, model.settings.value.articleSpeed)
            compose.activityRule.scenario.recreate()
            model = model()
            assertEquals(1.5f, model.settings.value.podcastSpeed)
            assertEquals(0.75f, model.settings.value.articleSpeed)
            compose.onNodeWithTag("speed-Articles").assertTextContains("0.75×")
        } finally {
            compose.runOnUiThread { model.pause(); model.setSpeed(ContentKind.Podcast, previous.podcastSpeed); model.setSpeed(ContentKind.Article, previous.articleSpeed) }
        }
    }

    @Test fun selectedVoicePreviewsPersistsAndIsUsedForNarration() {
        var model = model()
        val previous = model.settings.value
        try {
            compose.onNodeWithText("Settings").performClick()
            compose.waitUntil(20_000) { !model.voices.value.loading && (model.voices.value.voices.isNotEmpty() || model.voices.value.error != null) }
            if (model.voices.value.voices.isEmpty()) {
                compose.onNodeWithText("Download voices").assertIsDisplayed()
                assertNotNull(model.voices.value.error)
                return
            }
            val options = model.voices.value.voices
            val selected = options.getOrElse(1) { options.first() }
            compose.onNodeWithTag("voice-setting").performClick()
            compose.onNodeWithTag("voice-list").performScrollToNode(hasText(selected.label))
            compose.onNodeWithText(selected.label).performClick()
            compose.onNodeWithText("Listen to voice").performClick()
            compose.waitUntil(5_000) { model.voices.value.previewing || model.voices.value.error != null }
            assertNull(model.voices.value.error)
            compose.onNodeWithText("Stop voice preview").performClick()
            assertFalse(model.voices.value.previewing)
            compose.activityRule.scenario.recreate()
            model = model()
            assertEquals(selected.id, model.settings.value.voiceId)
            compose.waitUntil(10_000) { model.player.value.connected }
            compose.runOnUiThread { model.setSpeed(ContentKind.Article, 1.25f); model.play(model.library.first { it.id == "morning" }) }
            compose.waitUntil(90_000) { PlaybackStatus.state.value.error != null || (model.player.value.item?.id == "morning" && model.player.value.playing && PlaybackStatus.state.value.message == null) }
            assertNull(PlaybackStatus.state.value.error)
            assertEquals(selected.id, PlaybackStatus.state.value.voice)
            assertEquals(1.25f, model.player.value.speed)
            assertEquals(previous.podcastSpeed, model.settings.value.podcastSpeed)
        } finally {
            compose.runOnUiThread { model.pause(); model.selectVoice(previous.voiceId); model.setSpeed(ContentKind.Podcast, previous.podcastSpeed); model.setSpeed(ContentKind.Article, previous.articleSpeed) }
        }
    }
}
