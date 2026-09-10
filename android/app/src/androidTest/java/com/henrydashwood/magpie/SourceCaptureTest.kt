package com.henrydashwood.magpie

import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.lifecycle.ViewModelProvider
import com.henrydashwood.magpie.data.LinkInbox
import java.util.UUID
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

class SourceCaptureTest {
    @get:Rule val compose = createAndroidComposeRule<MainActivity>()

    @Test fun sourceCaptureValidatesPersistsAndStaysSeparateFromSaved() {
        val url = "https://example.org/magpie-source-test/${UUID.randomUUID()}"
        val model = compose.runOnUiThread { ViewModelProvider(compose.activity)[MagpieModel::class.java] }
        val inbox = LinkInbox(compose.activity.applicationContext, "magpie_source_inbox")
        try {
            compose.onNodeWithContentDescription("Add sources").performClick()
            compose.onNodeWithText("Cancel").performClick()
            assertFalse(inbox.links().contains(url))
            compose.onNodeWithContentDescription("Add sources").performClick()
            compose.onNodeWithText("Save").assertIsNotEnabled()
            compose.onNodeWithText("Feed or website address").performTextInput("not a link")
            compose.onNodeWithText("Save").performClick()
            compose.onNodeWithText("Enter a valid http:// or https:// web address.").assertIsDisplayed()
            compose.onNodeWithText("Feed or website address").performTextReplacement(url)
            compose.activityRule.scenario.recreate()
            compose.onNodeWithText("Feed or website address").assertTextContains(url)
            compose.onNodeWithText("Save").performClick()
            compose.waitUntil(5_000) { model.pendingSources.value.contains(url) && !model.sourceCapture.value.showing }
            compose.onNodeWithText(url).assertIsDisplayed()
            assertTrue(inbox.links().contains(url))
            compose.onNodeWithContentDescription("Add sources").performClick()
            compose.onNodeWithText("Feed or website address").performTextInput(url)
            compose.onNodeWithText("Save").performClick()
            compose.waitUntil(5_000) { !model.sourceCapture.value.showing }
            compose.onAllNodesWithText(url).assertCountEquals(1)
            compose.activityRule.scenario.recreate()
            compose.onNodeWithText(url).assertIsDisplayed()
            compose.onNodeWithContentDescription("Search").performClick()
            compose.onNodeWithText("Search your library").performTextInput("unmatched-capture-query")
            compose.onNodeWithText("Nothing found").assertIsDisplayed()
            compose.onNodeWithText("Search your library").performTextReplacement("magpie-source-test")
            compose.onNodeWithText(url).assertIsDisplayed()
            compose.onNodeWithContentDescription("Close search").performClick()
            compose.onNodeWithText("Saved").performClick()
            compose.onNodeWithContentDescription("Add sources").assertDoesNotExist()
            compose.onNodeWithText(url).assertDoesNotExist()
            assertFalse(LinkInbox(compose.activity.applicationContext).links().contains(url))
            compose.onNodeWithText("Following").performClick()
            compose.onNodeWithText(url).performTouchInput { longClick() }
            compose.onNodeWithText("Remove feed address").performClick()
            compose.waitUntil(5_000) { !model.pendingSources.value.contains(url) }
            assertFalse(inbox.links().contains(url))
        } finally {
            compose.runOnUiThread { model.closeSourceCapture(); model.removePendingSource(url) }
            compose.waitUntil(5_000) { !inbox.links().contains(url) }
        }
    }
}
