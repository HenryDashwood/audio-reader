package com.henrydashwood.magpie

import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.lifecycle.ViewModelProvider
import com.henrydashwood.magpie.data.LinkInbox
import java.util.UUID
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

class LinkCaptureTest {
    @get:Rule val compose = createAndroidComposeRule<MainActivity>()

    @Test fun linkCaptureValidatesPersistsDeduplicatesFiltersAndRemoves() {
        val url = "https://example.org/magpie-capture-test/${UUID.randomUUID()}"
        val model = compose.runOnUiThread { ViewModelProvider(compose.activity)[MagpieModel::class.java] }
        val inbox = LinkInbox(compose.activity.applicationContext)
        try {
            compose.onNodeWithContentDescription("Add link").assertDoesNotExist()
            compose.onNodeWithText("Saved").performClick()
            compose.onNodeWithText("Finished").performClick()
            compose.onNodeWithContentDescription("Add link").performClick()
            compose.onNodeWithText("Save").assertIsNotEnabled()
            compose.onNodeWithText("Web address").performTextInput("not a link")
            compose.onNodeWithText("Save").performClick()
            compose.onNodeWithText("Enter a valid http:// or https:// web address.").assertIsDisplayed()
            compose.onNodeWithText("Web address").performTextReplacement(url)
            compose.activityRule.scenario.recreate()
            compose.onNodeWithText("Web address").assertTextContains(url)
            compose.onNodeWithText("Save").performClick()
            compose.waitUntil(5_000) { model.pendingLinks.value.contains(url) && !model.linkCapture.value.showing }
            compose.onNodeWithText(url).assertIsDisplayed()
            assertTrue(inbox.links().contains(url))
            compose.onNodeWithContentDescription("Add link").performClick()
            compose.onNodeWithText("Web address").performTextInput(url)
            compose.onNodeWithText("Save").performClick()
            compose.waitUntil(5_000) { !model.linkCapture.value.showing }
            compose.onAllNodesWithText(url).assertCountEquals(1)
            compose.activityRule.scenario.recreate()
            compose.onNodeWithText(url).assertIsDisplayed()
            compose.onNodeWithContentDescription("Search").performClick()
            compose.onNodeWithText("Search saved articles").performTextInput("unmatched-capture-query")
            compose.onNodeWithText("Nothing found").assertIsDisplayed()
            compose.onNodeWithText("Search saved articles").performTextReplacement("magpie-capture-test")
            compose.onNodeWithText(url).assertIsDisplayed()
            compose.onNodeWithText("Finished").performClick()
            compose.onNodeWithText(url).assertDoesNotExist()
            compose.onNodeWithText("To read").performClick()
            compose.onNodeWithText(url).performTouchInput { longClick() }
            compose.onNodeWithText("Remove saved link").performClick()
            compose.waitUntil(5_000) { !model.pendingLinks.value.contains(url) }
            assertFalse(inbox.links().contains(url))
        } finally {
            compose.runOnUiThread { model.closeLinkCapture(); model.removePendingLink(url) }
            compose.waitUntil(5_000) { !inbox.links().contains(url) }
        }
    }
}
