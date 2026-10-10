package com.henrydashwood.magpie

import android.webkit.CookieManager
import android.webkit.WebResourceResponse
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.test.core.app.ApplicationProvider
import androidx.test.platform.app.InstrumentationRegistry
import com.henrydashwood.magpie.sharing.*
import com.henrydashwood.magpie.ui.MagpieTheme
import org.junit.*
import org.junit.Assert.*
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

class WebsiteSignInsTest {
    @get:Rule val compose = createComposeRule()
    private val store = WebsiteSignInStore(ApplicationProvider.getApplicationContext())
    private fun signOut() {
        val done = CountDownLatch(1)
        InstrumentationRegistry.getInstrumentation().runOnMainSync { store.signOutAll { done.countDown() } }
        assertTrue(done.await(10, TimeUnit.SECONDS))
    }
    @Before fun setup() {
        signOut()
        CaptureFixtures.respond = { WebResourceResponse("text/html", "UTF-8", "<html><body><p>Sign in</p></body></html>".byteInputStream()) }
    }
    @After fun cleanup() { CaptureFixtures.respond = null; signOut() }

    @Test fun openingAWebsiteRemembersItAndSigningOutForgetsCookies() {
        var closed = false
        compose.setContent { MagpieTheme { WebsiteSignInsScreen { closed = true } } }
        compose.onNodeWithText("Open website").performClick()
        compose.onNodeWithText("Enter a website address, such as nytimes.com.").assertExists()
        compose.onNodeWithText("Website address").performTextInput("www.capture-fixture.invalid/login")
        compose.onNodeWithText("Open website").performClick()
        compose.onNodeWithText("Website sign-in").assertExists()
        compose.onNodeWithText("Preview article").assertDoesNotExist()
        // A sign-in keeps its cookie for later hidden captures.
        InstrumentationRegistry.getInstrumentation().runOnMainSync {
            CookieManager.getInstance().setCookie("https://www.capture-fixture.invalid", "session=1; Secure")
        }
        compose.onNodeWithText("Done").performClick()
        compose.onNodeWithText("capture-fixture.invalid").assertExists()
        assertEquals(listOf("https://www.capture-fixture.invalid"), store.sites())
        compose.onNodeWithText("Sign out of all websites").performScrollTo().performClick()
        compose.onNodeWithText("Sign Out").performClick()
        compose.waitUntil(10_000) { compose.onAllNodesWithText("Signed out of all websites.").fetchSemanticsNodes().isNotEmpty() }
        compose.onNodeWithText("capture-fixture.invalid").assertDoesNotExist()
        assertNull(CookieManager.getInstance().getCookie("https://www.capture-fixture.invalid"))
        assertFalse(closed)
    }
}
