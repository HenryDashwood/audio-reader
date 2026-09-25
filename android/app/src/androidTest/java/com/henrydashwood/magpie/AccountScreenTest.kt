package com.henrydashwood.magpie

import android.content.Context
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.mutableStateOf
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.LifecycleRegistry
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createComposeRule
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
        compose.setContent { MagpieTheme { AccountContent(state, configured, {}, {}, {}, {}) } }
    }
    // LazyColumn does not compose every off-screen item on smaller phones.
    private fun scrollTo(text: String): SemanticsNodeInteraction {
        compose.onNode(hasScrollToIndexAction()).performScrollToNode(hasText(text))
        return compose.onNodeWithText(text).performScrollTo()
    }
    @Test fun unavailableConfigurationExplainsTheBoundary() {
        show(configured = false)
        scrollTo("Sign in with Google").assertIsNotEnabled()
        scrollTo("Google sign-in is not available in this build yet.").assertIsDisplayed()
        scrollTo("Android preview · Sample library").assertIsDisplayed()
    }
    @Test fun bothConnectedProvidersAreVisible() {
        show(AccountState(signedIn = true, providers = setOf("apple", "google")))
        // As on iOS: a section per provider, each marked Connected.
        compose.onAllNodesWithText("Connected").assertCountEquals(2)
        compose.onNodeWithText("Continue with Google").assertDoesNotExist()
    }
    @Test fun linkConflictLeavesTheExistingProviderVisible() {
        show(AccountState(signedIn = true, providers = setOf("apple"), error = "Already linked to another account"))
        scrollTo("Connected").assertIsDisplayed()
        scrollTo("Continue with Google").assertIsEnabled()
        scrollTo("Already linked to another account").assertIsDisplayed()
    }
    @Test fun deletionRequiresExplicitConfirmationAndCanBeCancelled() {
        var deletions = 0
        // As on iOS, Sign Out and Delete Account are in Settings' Account section.
        compose.setContent { MagpieTheme { com.henrydashwood.magpie.ui.AccountActions(AccountState(signedIn = true), {}, { deletions++ }) } }
        compose.onNodeWithText("Delete Account").performClick()
        compose.onNodeWithText("Delete your account?").assertIsDisplayed()
        assertEquals(0, deletions)
        compose.onNodeWithText("Cancel").performClick()
        assertEquals(0, deletions)
        compose.onNodeWithText("Delete Account").performClick()
        compose.onNode(hasText("Delete Account") and hasAnyAncestor(isDialog())).performClick()
        compose.runOnIdle { assertEquals(1, deletions) }
    }
    @Test fun appleIsAvailableWithoutGoogleConfiguration() {
        var clicked = false
        compose.setContent { MagpieTheme {
            AccountContent(AccountState(), false, {}, {}, {}, {}, appleConfigured = true,
                signInApple = { clicked = true })
        } }
        scrollTo("Sign in with Apple").assertIsEnabled().performClick()
        compose.runOnIdle { assertTrue(clicked) }
        scrollTo("Sign in with Google").assertIsNotEnabled()
    }
    @Test fun googleAccountCanConnectAppleFromAndroid() {
        var linked = false
        compose.setContent { MagpieTheme {
            AccountContent(AccountState(signedIn = true, providers = setOf("google")), true,
                {}, {}, {}, {}, appleConfigured = true, linkApple = { linked = true })
        } }
        scrollTo("Connect your Apple account").assertIsDisplayed()
        scrollTo("Continue with Apple").performClick()
        compose.runOnIdle { assertTrue(linked) }
    }
    @Test fun pendingBrowserSignInCanBeCancelledAndPreventsAnotherProvider() {
        var cancelled = false
        compose.setContent { MagpieTheme {
            AccountContent(AccountState(applePending = true, busy = true), true, {}, {}, {}, {},
                appleConfigured = true, cancelApple = { cancelled = true })
        } }
        scrollTo("Sign in with Apple").assertIsNotEnabled()
        scrollTo("Sign in with Google").assertIsNotEnabled()
        scrollTo("Cancel Apple sign-in").performClick()
        compose.runOnIdle { assertTrue(cancelled) }
    }
    @Test fun returningToForegroundChecksAFailedAppleAttemptAgain() {
        val owner = object : LifecycleOwner {
            val registry = LifecycleRegistry(this)
            override val lifecycle: Lifecycle get() = registry
        }
        val state = mutableStateOf(AccountState(applePending = true, busy = true))
        var checks = 0
        compose.runOnUiThread { owner.registry.currentState = Lifecycle.State.RESUMED }
        compose.setContent { CompositionLocalProvider(LocalLifecycleOwner provides owner) {
            MagpieTheme { AccountContent(state.value, true, {}, {}, {}, {},
                appleConfigured = true, resumeApple = { checks++ }) }
        } }
        compose.runOnIdle {
            assertEquals(1, checks)
            owner.registry.currentState = Lifecycle.State.CREATED
            state.value = state.value.copy(busy = false, error = "Could not connect to Magpie.")
        }
        compose.waitForIdle()
        compose.runOnIdle {
            assertEquals(1, checks) // Recomposition in the background is not a retry.
            owner.registry.currentState = Lifecycle.State.RESUMED
        }
        compose.runOnIdle {
            assertEquals(2, checks)
            state.value = AccountState(signedIn = true, providers = setOf("apple"))
        }
        compose.waitForIdle()
        compose.runOnIdle {
            owner.registry.currentState = Lifecycle.State.CREATED
            owner.registry.currentState = Lifecycle.State.RESUMED
            assertEquals(2, checks) // A completed attempt must not be replayed.
            owner.registry.currentState = Lifecycle.State.DESTROYED
        }
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
