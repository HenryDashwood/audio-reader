package com.henrydashwood.magpie

import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.layout.Row
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createComposeRule
import com.henrydashwood.magpie.data.ContentKind
import com.henrydashwood.magpie.data.SampleLibrary
import com.henrydashwood.magpie.ui.MagpieTheme
import com.henrydashwood.magpie.ui.ReaderToolbarActions
import kotlinx.coroutines.CompletableDeferred
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

class ArticleShareTest {
    @get:Rule val compose = createComposeRule()
    private val article = SampleLibrary().items.first { it.kind == ContentKind.Article }.copy(textLoaded = true)

    @Test fun linkedArticleOffersBothChoicesAndNewsletterGoesDirectlyToPDF() {
        val item = mutableStateOf(article.copy(originalUrl = "https://example.org/story"))
        val launched = mutableListOf<Intent>()
        var exports = 0
        compose.setContent { MagpieTheme { Row {
            ReaderToolbarActions(item.value, false, false, {}, {}, launched::add,
                exportPDF = { exports++; Uri.parse("content://example.org/article.pdf") })
        } } }
        compose.onNodeWithContentDescription("Share article").performClick()
        compose.onNodeWithText("Share link").assertIsDisplayed()
        compose.onNodeWithText("Export as PDF").assertIsDisplayed()
        compose.onNodeWithText("Export as PDF").performClick()
        compose.waitUntil { launched.size == 1 }
        compose.runOnIdle { assertEquals(1, exports) }
        compose.runOnIdle { item.value = article.copy(originalUrl = null) }
        compose.onNodeWithContentDescription("Share article").performClick()
        compose.waitUntil { launched.size == 2 }
        compose.onNodeWithText("Share link").assertDoesNotExist()
        compose.runOnIdle { assertEquals(2, exports) }
    }

    @Test fun leavingTheArticleCancelsPendingShareAndFailureCanBeRetried() {
        val item = mutableStateOf(article.copy(originalUrl = null))
        val result = CompletableDeferred<Uri>()
        val launched = mutableListOf<Intent>()
        var started = false
        var fail = false
        compose.setContent { MagpieTheme { Row {
            ReaderToolbarActions(item.value, false, false, {}, {}, launched::add, exportPDF = {
                started = true
                if (fail) error("Please try again.")
                result.await()
            })
        } } }
        compose.onNodeWithContentDescription("Share article").performClick()
        compose.waitUntil { started }
        compose.runOnIdle { item.value = item.value.copy(id = "different"); fail = true }
        compose.waitForIdle() // Apply navigation and dispose the old toolbar before its response arrives.
        result.complete(Uri.parse("content://example.org/old.pdf"))
        compose.waitForIdle()
        compose.runOnIdle { assertTrue(launched.isEmpty()) }
        compose.onNodeWithContentDescription("Share article").performClick()
        compose.onNodeWithText("Could not export PDF").assertIsDisplayed()
        compose.runOnIdle { fail = false }
        compose.onNodeWithText("Try again").performClick()
        compose.waitUntil { launched.size == 1 }
    }
}
