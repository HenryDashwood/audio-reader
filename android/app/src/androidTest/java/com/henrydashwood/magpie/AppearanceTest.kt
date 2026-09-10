package com.henrydashwood.magpie

import android.graphics.Bitmap
import androidx.activity.compose.setContent
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.unit.Density
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.test.platform.app.InstrumentationRegistry
import com.henrydashwood.magpie.ui.MagpieApp
import com.henrydashwood.magpie.ui.MagpieTheme
import java.io.File
import org.junit.Rule
import org.junit.Test

class AppearanceTest {
    @get:Rule val compose = createAndroidComposeRule<MainActivity>()

    private fun screenshot(name: String) {
        compose.waitForIdle()
        // Compose's node capture reads the activity window even for a modal sheet.
        // Capture the displayed windows so the image matches what the user sees.
        val bitmap = checkNotNull(InstrumentationRegistry.getInstrumentation().uiAutomation.takeScreenshot())
        val supplied = InstrumentationRegistry.getArguments().getString("additionalTestOutputDir")
        val directory = supplied?.let(::File) ?: File(compose.activity.filesDir, "screenshots")
        directory.mkdirs()
        File(directory, "$name.png").outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
    }

    @Test fun followingAndReaderAtNormalSize() {
        compose.onNodeWithText("Field notes").assertIsDisplayed()
        screenshot("following")
        compose.onNodeWithText("Field notes").performClick()
        screenshot("source")
        compose.onNodeWithContentDescription("Manage Field notes").performClick()
        screenshot("source-menu")
        compose.onNodeWithText("Manage sources").performClick()
        screenshot("source-management")
        compose.onNodeWithContentDescription("Close source management").performClick()
        compose.onNodeWithText("The pleasure of taking the long way home").performClick()
        screenshot("reader")
        compose.onNodeWithText("Latest").performClick()
        screenshot("latest")
        compose.onNodeWithContentDescription("Clear Latest").performClick()
        compose.onNodeWithText("Clear Latest?").assertIsDisplayed()
        screenshot("clear-latest")
        compose.onNodeWithText("Cancel").performClick()
        compose.onNodeWithText("Saved").performClick()
        screenshot("saved")
        compose.onNodeWithContentDescription("Add link").performClick()
        compose.onNodeWithText("Web address").assertIsDisplayed()
        screenshot("add-link")
        compose.onNodeWithText("Cancel").performClick()
        compose.onNodeWithText("Settings").performClick()
        screenshot("settings")
        compose.onNodeWithText("Latest").performClick()
        compose.onNodeWithContentDescription("Play A little more room to listen").performClick()
        compose.waitUntil(10_000) { compose.onAllNodesWithContentDescription("Pause playback").fetchSemanticsNodes().isNotEmpty() }
        compose.onNodeWithContentDescription("Pause playback").performClick()
        compose.onNodeWithTag("mini-player-open").performClick()
        compose.onNodeWithContentDescription("Close player").assertIsDisplayed()
        screenshot("player")
        compose.onNodeWithContentDescription("Close player").performClick()
        compose.onNodeWithTag("mini-player-open").assertIsDisplayed()
    }

    @Test fun largeTextAndDarkThemeRemainNavigable() {
        compose.runOnUiThread {
            compose.activity.setContent {
                val density = LocalDensity.current.density
                CompositionLocalProvider(LocalDensity provides Density(density, fontScale = 2f)) {
                    MagpieTheme(darkTheme = true) { MagpieApp(viewModel()) }
                }
            }
        }
        compose.onNodeWithTag("following-list").performScrollToNode(hasText("Field notes"))
        compose.onNodeWithText("Field notes").assertIsDisplayed()
        screenshot("following-large-dark")
        compose.onNodeWithText("Field notes").performClick()
        compose.onNodeWithContentDescription("Manage Field notes").assertIsDisplayed().performClick()
        compose.onNodeWithText("Manage sources").performClick()
        compose.onNodeWithTag("feed-sources-list").performScrollToNode(hasText("Bundled sample content"))
        compose.onNodeWithText("Bundled sample content").assertIsDisplayed()
        screenshot("source-management-large-dark")
        compose.onNodeWithContentDescription("Close source management").performClick()
        compose.onNodeWithText("Latest").performClick()
        compose.onNodeWithTag("story-list").performScrollToNode(hasText("The pleasure of taking the long way home"))
        compose.onNodeWithText("The pleasure of taking the long way home").performClick()
        compose.onNodeWithContentDescription("Listen").assertIsDisplayed()
        screenshot("reader-large-dark")
        compose.onNodeWithContentDescription("Back").assertIsDisplayed()
        compose.onNodeWithText("Settings").performClick()
        compose.onNodeWithTag("speed-Podcasts").assertIsDisplayed()
        screenshot("settings-large-dark")
        compose.onNodeWithTag("settings-list").performScrollToNode(hasText("Privacy Policy"))
        compose.onNodeWithText("Privacy Policy").assertIsDisplayed()
        screenshot("settings-support-large-dark")
    }
}
