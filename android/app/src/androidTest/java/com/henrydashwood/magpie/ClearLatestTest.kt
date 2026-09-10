package com.henrydashwood.magpie

import android.content.Context
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.core.content.edit
import androidx.lifecycle.ViewModelProvider
import com.henrydashwood.magpie.data.PreviewStore
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

class ClearLatestTest {
    @get:Rule val compose = createAndroidComposeRule<MainActivity>()

    @Test fun clearRequiresConfirmationPersistsAndPreservesTheLibrary() {
        val context = compose.activity.applicationContext
        val store = PreviewStore(context)
        val beforeDismissed = store.dismissedFromLatest
        val beforeSaved = store.saved
        val beforeFinished = store.finished
        val beforeBookmark = store.bookmark("walking")
        val model = compose.runOnUiThread { ViewModelProvider(compose.activity)[MagpieModel::class.java] }
        try {
            compose.onNodeWithContentDescription("Clear Latest").assertDoesNotExist()
            compose.onNodeWithText("Latest").performClick()
            compose.onNodeWithContentDescription("Clear Latest").performClick()
            compose.onNodeWithText("Clear Latest?").assertIsDisplayed()
            compose.onNodeWithText("This removes all current items from Latest without marking them as played. New episodes will still appear.").assertIsDisplayed()
            compose.activityRule.scenario.recreate()
            compose.onNodeWithText("Clear Latest?").assertIsDisplayed()
            compose.onNodeWithText("Cancel").performClick()
            assertEquals(beforeDismissed, store.dismissedFromLatest)
            compose.onNodeWithText("The pleasure of taking the long way home").assertIsDisplayed()
            compose.onNodeWithContentDescription("Clear Latest").performClick()
            compose.onNodeWithText("Clear Latest").performClick()
            compose.waitUntil(5_000) { model.dismissedFromLatest.value.containsAll(model.library.map { it.id }) }
            compose.onNodeWithText("You're caught up").assertIsDisplayed()
            compose.onNodeWithContentDescription("Clear Latest").assertDoesNotExist()
            compose.onNodeWithContentDescription("Ask Magpie").assertIsDisplayed()
            compose.activityRule.scenario.recreate()
            compose.onNodeWithText("You're caught up").assertIsDisplayed()
            assertEquals(beforeSaved, store.saved)
            assertEquals(beforeFinished, store.finished)
            assertEquals(beforeBookmark, store.bookmark("walking"))
            assertTrue(PreviewStore(context).dismissedFromLatest.containsAll(model.library.map { it.id }))
            compose.onNodeWithText("Following").performClick()
            compose.onNodeWithText("Field notes").performClick()
            compose.onNodeWithText("The pleasure of taking the long way home").assertIsDisplayed()
        } finally {
            // Restore only the flag this test changes, leaving saved articles and bookmarks intact.
            context.getSharedPreferences("magpie_preview", Context.MODE_PRIVATE).edit(commit = true) {
                putStringSet("latest_dismissed", beforeDismissed)
            }
        }
    }
}
