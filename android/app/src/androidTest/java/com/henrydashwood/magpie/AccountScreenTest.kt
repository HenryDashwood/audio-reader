package com.henrydashwood.magpie

import android.content.Context
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.henrydashwood.magpie.auth.*
import com.henrydashwood.magpie.ui.MagpieTheme
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class AccountScreenTest {
    @get:Rule val compose = createComposeRule()
    private fun show(state: AccountState = AccountState(), configured: Boolean = true, delete: () -> Unit = {}) {
        compose.setContent { MagpieTheme { AccountContent(state, configured, {}, {}, {}, {}, {}, delete) } }
    }
    @Test fun unavailableConfigurationExplainsTheBoundary() {
        show(configured = false)
        compose.onNodeWithText("Sign in with Google").performScrollTo().assertIsNotEnabled()
        compose.onNodeWithText("Google sign-in is not available in this build yet.").performScrollTo().assertIsDisplayed()
        compose.onNodeWithText("Android preview · Sample library").performScrollTo().assertIsDisplayed()
    }
    @Test fun bothConnectedProvidersAreVisible() {
        show(AccountState(signedIn = true, providers = setOf("apple", "google")))
        compose.onNodeWithText("Apple · Connected").performScrollTo().assertIsDisplayed()
        compose.onNodeWithText("Google · Connected").performScrollTo().assertIsDisplayed()
        compose.onNodeWithText("Sign in with Google").assertDoesNotExist()
    }
    @Test fun linkConflictLeavesTheExistingProviderVisible() {
        show(AccountState(signedIn = true, providers = setOf("apple"), error = "Already linked to another account"))
        compose.onNodeWithText("Apple · Connected").performScrollTo().assertIsDisplayed()
        compose.onNodeWithText("Sign in with Google").performScrollTo().assertIsEnabled()
        compose.onNodeWithText("Already linked to another account").performScrollTo().assertIsDisplayed()
    }
    @Test fun deletionRequiresExplicitConfirmationAndCanBeCancelled() {
        var deletions = 0
        show(AccountState(signedIn = true, providers = setOf("google")), delete = { deletions++ })
        compose.onNodeWithText("Delete Account").performScrollTo().performClick()
        compose.onNodeWithText("Delete your account?").assertIsDisplayed()
        assertEquals(0, deletions)
        compose.onNodeWithText("Cancel").performClick()
        assertEquals(0, deletions)
        compose.onNodeWithText("Delete Account").performScrollTo().performClick()
        compose.onNode(hasText("Delete Account") and hasAnyAncestor(isDialog())).performClick()
        compose.runOnIdle { assertEquals(1, deletions) }
    }
    @Test fun appleIsAvailableWithoutGoogleConfiguration() {
        var clicked = false
        compose.setContent { MagpieTheme {
            AccountContent(AccountState(), false, {}, {}, {}, {}, {}, {}, appleConfigured = true,
                signInApple = { clicked = true })
        } }
        compose.onNodeWithText("Sign in with Apple").performScrollTo().assertIsEnabled().performClick()
        compose.runOnIdle { assertTrue(clicked) }
        compose.onNodeWithText("Sign in with Google").performScrollTo().assertIsNotEnabled()
    }
    @Test fun googleAccountCanConnectAppleFromAndroid() {
        var linked = false
        compose.setContent { MagpieTheme {
            AccountContent(AccountState(signedIn = true, providers = setOf("google")), true,
                {}, {}, {}, {}, {}, {}, appleConfigured = true, linkApple = { linked = true })
        } }
        compose.onNodeWithText("Connect your Apple account").performScrollTo().assertIsDisplayed()
        compose.onNodeWithText("Sign in with Apple").performScrollTo().performClick()
        compose.runOnIdle { assertTrue(linked) }
    }
    @Test fun pendingBrowserSignInCanBeCancelledAndPreventsAnotherProvider() {
        var cancelled = false
        compose.setContent { MagpieTheme {
            AccountContent(AccountState(applePending = true, busy = true), true, {}, {}, {}, {}, {}, {},
                appleConfigured = true, cancelApple = { cancelled = true })
        } }
        compose.onNodeWithText("Sign in with Apple").performScrollTo().assertIsNotEnabled()
        compose.onNodeWithText("Sign in with Google").performScrollTo().assertIsNotEnabled()
        compose.onNodeWithText("Cancel Apple sign-in").performScrollTo().performClick()
        compose.runOnIdle { assertTrue(cancelled) }
    }
    @Test fun browserHandoffSurvivesRecreationInEncryptedStorage() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val name = "test-apple-pending-encryption"
        val encrypted = EncryptedAccountTokenStore(context, "https://one.example", name)
        val store = EncryptedApplePendingStore(encrypted)
        try {
            val value = ApplePending("s".repeat(43), "v".repeat(43), "https://appleid.apple.com/auth/authorize", 1234L, null)
            store.write(value)
            assertEquals(value, EncryptedApplePendingStore(EncryptedAccountTokenStore(context, "https://one.example", name)).read())
            assertFalse(context.getSharedPreferences(name, Context.MODE_PRIVATE).getString("session", "")!!.contains(value.verifier))
        } finally { store.clear() }
    }
    @Test fun sessionIsEncryptedAndCannotMoveBetweenServers() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val name = "test-account-encryption"
        val prefs = context.getSharedPreferences(name, Context.MODE_PRIVATE)
        prefs.edit().clear().commit()
        try {
            val store = EncryptedAccountTokenStore(context, "https://one.example", name)
            store.write("private-session-token")
            assertEquals("private-session-token", store.read())
            assertFalse(prefs.getString("session", "")!!.contains("private-session-token"))
            assertNull(EncryptedAccountTokenStore(context, "https://two.example", name).read())
            store.write("another-token"); store.clear(); assertNull(store.read())
        } finally { prefs.edit().clear().commit() }
    }
}
