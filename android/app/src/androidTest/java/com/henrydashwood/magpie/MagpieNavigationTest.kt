package com.henrydashwood.magpie

import androidx.compose.ui.test.*
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.henrydashwood.magpie.data.SampleLibrary
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class MagpieNavigationTest {
    @get:Rule val compose = createAndroidComposeRule<MainActivity>()
    private val article = SampleLibrary().items.first { it.id == "walking" }

    @Test fun sourceOpensArticleAndBackReturnsToSource() {
        compose.onNodeWithText("Field notes").performClick()
        compose.onNodeWithText(article.title).performClick()
        compose.onNodeWithContentDescription("Open the original").assertIsDisplayed().assertIsNotEnabled()
        compose.onNodeWithContentDescription("Share sample text").assertIsDisplayed()
        compose.onNodeWithContentDescription("Ask Magpie").assertIsDisplayed()
        compose.onNodeWithContentDescription("More options for ${article.title}").assertDoesNotExist()
        val lastParagraph = article.text.split("\n\n").last()
        compose.onNodeWithTag("reader-list").performScrollToNode(hasText(lastParagraph))
        compose.onNodeWithText(lastParagraph).assertIsDisplayed()
        compose.onNodeWithContentDescription("Find in this page").performClick()
        compose.onNodeWithText("Find in this page").performTextInput("blackbird")
        compose.onNodeWithText("1 of 1 paragraphs").assertIsDisplayed()
        compose.onNodeWithText(article.text.split("\n\n")[1]).assertIsDisplayed()
        compose.onNodeWithContentDescription("Close search").performClick()
        compose.onNodeWithContentDescription("Back").performClick()
        compose.onNode(hasText("Field notes") and SemanticsMatcher.keyIsDefined(SemanticsProperties.Heading)).assertIsDisplayed()
        compose.onNodeWithTag("story-list").assertExists()
    }

    @Test fun feedMenuShowsSourceManagementAndExplainsSampleLimitations() {
        compose.onNodeWithText("Field notes").performClick()
        compose.onNodeWithContentDescription("Manage Field notes").performClick()
        compose.onNodeWithText("Unsubscribe").assertIsNotEnabled()
        compose.onNodeWithText("Requires a connected account").assertIsDisplayed()
        compose.onNodeWithText("Manage sources").performClick()
        compose.onNodeWithText("Sources in Field notes").assertIsDisplayed()
        compose.onNodeWithText("Bundled sample content").assertIsDisplayed()
        compose.activityRule.scenario.recreate()
        compose.onNodeWithContentDescription("Close source management").performClick()
        compose.onNodeWithText(article.title).assertIsDisplayed()
        compose.onNodeWithContentDescription("Search").performClick()
        compose.onNodeWithText("Search this show").performTextInput("blackbird")
        compose.onNodeWithContentDescription("Close search").performClick()
        compose.onNodeWithContentDescription("Manage Field notes").assertIsDisplayed()
    }

    @Test fun navigationAndToolbarSearchAreUsable() {
        compose.onNodeWithContentDescription("Search").performClick()
        compose.onNodeWithText("Search your library").performTextInput("not a real story")
        compose.onNodeWithText("Nothing found").assertIsDisplayed()
        compose.onNodeWithContentDescription("Close search").performClick()
        compose.onNodeWithText("Field notes").assertIsDisplayed()
        compose.onNodeWithText("Latest").performClick()
        compose.onNodeWithText(article.title).assertExists()
        compose.onNodeWithContentDescription("More options for ${article.title}").assertDoesNotExist()
        compose.onNodeWithContentDescription("Search").assertDoesNotExist()
        compose.onNodeWithText("Settings").performClick()
        compose.onNodeWithText("Playback Speed").assertIsDisplayed()
        compose.onNodeWithText("Saved").performClick()
        compose.onNodeWithContentDescription("Search").performClick()
        compose.onNodeWithText("Search saved articles").performTextInput("not a real story")
        compose.onNodeWithText("Nothing found").assertIsDisplayed()
    }

    @Test fun askMagpieIsAvailableAcrossTabsFeedAndSearch() {
        for (tab in listOf("Following", "Latest", "Saved", "Settings")) {
            if (tab != "Following") compose.onNodeWithText(tab).performClick()
            compose.onAllNodesWithContentDescription("Ask Magpie").assertCountEquals(1)
            compose.onNodeWithContentDescription("Ask Magpie").performClick()
            compose.onNodeWithText("No microphone audio is being recorded.", substring = true).assertIsDisplayed()
            if (tab == "Settings") compose.activityRule.scenario.recreate()
            compose.onNodeWithText("Close").performClick()
        }
        compose.onNodeWithText("Following").performClick()
        compose.onNodeWithText("Field notes").performClick()
        compose.onNodeWithContentDescription("Search").performClick()
        compose.onNodeWithText("Search this show").performTextInput("pleasure")
        compose.onNodeWithContentDescription("Ask Magpie").performClick()
        compose.onNodeWithText("Close").performClick()
        compose.onNodeWithText("Search this show").assertTextContains("pleasure")
        compose.onNodeWithContentDescription("Close search").performClick()
        compose.onNodeWithContentDescription("Manage Field notes").assertIsDisplayed()
    }

    @Test fun finishedArticlesMoveBetweenSavedFiltersAndSurviveRecreation() {
        compose.onNodeWithText("Saved").performClick()
        compose.onNodeWithText(article.title).performTouchInput { swipeLeft() }
        compose.onNodeWithText(article.title).assertDoesNotExist()
        compose.onNodeWithText("Finished").performClick()
        compose.onNodeWithText(article.title).assertIsDisplayed()
        compose.activityRule.scenario.recreate()
        compose.onNodeWithText(article.title).assertIsDisplayed()
        compose.onNodeWithText(article.title).performTouchInput { longClick() }
        compose.onNodeWithText("Mark as unread").performClick()
        compose.onNodeWithText(article.title).assertDoesNotExist()
        compose.onNodeWithText("To read").performClick()
        compose.onNodeWithText(article.title).assertIsDisplayed()
    }

    @Test fun articleActionsRemainAvailableWithoutRowButtons() {
        compose.onNodeWithText("Latest").performClick()
        compose.onNodeWithText(article.title).performTouchInput { longClick() }
        compose.onNodeWithText("Dismiss from Saved").performClick()
        compose.onNodeWithText(article.title).performTouchInput { swipeRight() }
        val row = compose.onNodeWithText(article.title).fetchSemanticsNode()
        org.junit.Assert.assertTrue(row.config[SemanticsActions.CustomActions].any { it.label == "Dismiss from Saved" })
        compose.onNodeWithText("Saved").performClick()
        compose.onNodeWithText(article.title).assertIsDisplayed()
    }
}
