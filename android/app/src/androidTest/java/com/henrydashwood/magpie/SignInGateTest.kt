package com.henrydashwood.magpie

import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createEmptyComposeRule
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import org.junit.After
import org.junit.Rule
import org.junit.Test

/** As on iOS, the app opens to sign-in until a session exists. */
class SignInGateTest {
    @get:Rule val compose = createEmptyComposeRule()
    private val app get() = ApplicationProvider.getApplicationContext<MagpieTestApplication>()
    private var scenario: ActivityScenario<MainActivity>? = null

    @After fun finish() { scenario?.close(); app.requireSignIn = false }

    @Test fun signedOutLaunchShowsOnlySignIn() {
        app.requireSignIn = true
        scenario = ActivityScenario.launch(MainActivity::class.java)
        compose.onNodeWithText("Sign in so your shows and listening positions follow you.").assertIsDisplayed()
        compose.onNodeWithText("Sign in with Apple").assertExists()
        compose.onNodeWithText("Sign in with Google").assertExists()
        compose.onNodeWithText("Magpie journal").assertDoesNotExist()
        compose.onNodeWithText("Latest").assertDoesNotExist()
    }
}
