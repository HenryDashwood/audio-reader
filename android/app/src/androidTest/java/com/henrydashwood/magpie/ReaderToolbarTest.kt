package com.henrydashwood.magpie

import android.content.ActivityNotFoundException
import android.content.Intent
import androidx.compose.foundation.layout.Row
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.core.content.IntentCompat
import com.henrydashwood.magpie.data.ContentKind
import com.henrydashwood.magpie.data.SampleLibrary
import com.henrydashwood.magpie.ui.MagpieTheme
import com.henrydashwood.magpie.ui.ReaderToolbarActions
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

class ReaderToolbarTest {
    @get:Rule val compose = createComposeRule()
    private val article = SampleLibrary().items.first { it.kind == ContentKind.Article }

    @Test fun originalAndShareUseTheSameLinkForArticlesAndEpisodes() {
        val item = mutableStateOf(article.copy(originalUrl = "https://example.org/story?part=2"))
        val launched = mutableListOf<Intent>()
        compose.setContent {
            MagpieTheme { Row { ReaderToolbarActions(item.value, false, false, {}, {}, launched::add) } }
        }
        for (kind in ContentKind.entries) {
            compose.runOnIdle { item.value = item.value.copy(kind = kind) }
            compose.onNodeWithContentDescription("Open the original").performClick()
            compose.runOnIdle {
                assertEquals(Intent.ACTION_VIEW, launched.last().action)
                assertEquals(item.value.originalUrl, launched.last().dataString)
            }
            compose.onNodeWithContentDescription("Share link").performClick()
            compose.runOnIdle {
                val chooser = launched.last()
                assertEquals(Intent.ACTION_CHOOSER, chooser.action)
                val share = checkNotNull(IntentCompat.getParcelableExtra(chooser, Intent.EXTRA_INTENT, Intent::class.java))
                assertEquals(Intent.ACTION_SEND, share.action)
                assertEquals("text/plain", share.type)
                assertEquals(item.value.originalUrl, share.getStringExtra(Intent.EXTRA_TEXT))
                assertEquals(item.value.title, share.getStringExtra(Intent.EXTRA_SUBJECT))
            }
        }
    }

    @Test fun sampleToolbarSharesTextAndExplainsUnavailableConversation() {
        val playing = mutableStateOf(false)
        val searching = mutableStateOf(false)
        var shared: Intent? = null
        compose.setContent {
            MagpieTheme { Row {
                ReaderToolbarActions(article, playing.value, searching.value, { playing.value = !playing.value },
                    { searching.value = !searching.value }, { shared = it })
            } }
        }
        compose.onNodeWithContentDescription("Listen").performClick()
        compose.onNodeWithContentDescription("Pause").assertIsDisplayed()
        compose.onNodeWithContentDescription("Open the original").assertIsNotEnabled()
        compose.onNodeWithContentDescription("Share sample text").performClick()
        compose.runOnIdle {
            val share = checkNotNull(IntentCompat.getParcelableExtra(checkNotNull(shared), Intent.EXTRA_INTENT, Intent::class.java))
            assertTrue(checkNotNull(share.getStringExtra(Intent.EXTRA_TEXT)).contains(article.text))
        }
        compose.onNodeWithContentDescription("Find in this page").performClick()
        compose.onNodeWithContentDescription("Close search").assertIsDisplayed()
        compose.onNodeWithContentDescription("Ask Magpie").performClick()
        compose.onNodeWithText("No microphone audio is being recorded.", substring = true).assertIsDisplayed()
        compose.onNodeWithText("Close").performClick()
        compose.onNodeWithContentDescription("Ask Magpie").assertIsDisplayed()
    }

    @Test fun unavailableBrowserHasAnActionableErrorAndUnsafeLinksAreDisabled() {
        val item = mutableStateOf(article.copy(originalUrl = "https://example.org/story"))
        compose.setContent {
            MagpieTheme { Row { ReaderToolbarActions(item.value, false, false, {}, {}, { throw ActivityNotFoundException() }) } }
        }
        compose.onNodeWithContentDescription("Open the original").performClick()
        compose.onNodeWithText("No app is available to open this action.").assertIsDisplayed()
        compose.onNodeWithText("Close").performClick()
        compose.runOnIdle { item.value = article.copy(originalUrl = "file:///private/story") }
        compose.onNodeWithContentDescription("Open the original").assertIsNotEnabled()
    }
}
