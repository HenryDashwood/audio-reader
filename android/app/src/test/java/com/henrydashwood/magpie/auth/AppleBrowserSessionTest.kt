package com.henrydashwood.magpie.auth

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.ExperimentalCoroutinesApi
import org.junit.Assert.*
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class AppleBrowserSessionTest {
    private class Store(var token: String? = null) : AccountTokenStore {
        override fun read() = token
        override fun write(token: String) { this.token = token }
        override fun clear() { token = null }
    }
    private class Api : AccountApi {
        var startSession: String? = null
        var finishSession: String? = null
        var challenge: String? = null
        var finishCount = 0
        var cancelled = false
        var fail = false
        var connectionFailure = false
        var gate: CompletableDeferred<Unit>? = null
        val auth = AccountLogin("apple-session", AccountUser("same-user", null))
        var result = AppleBrowserResult("complete", auth = auth)
        val loggedOut = mutableListOf<String>()
        override suspend fun startApple(challenge: String, session: String?): AppleBrowserStart {
            this.challenge = challenge; startSession = session
            return AppleBrowserStart("s".repeat(43), "https://appleid.apple.com/auth/authorize?state=example", 300)
        }
        override suspend fun completeApple(state: String, verifier: String, session: String?): AppleBrowserResult {
            finishCount++; finishSession = session
            gate?.await()
            if (connectionFailure) throw java.net.SocketTimeoutException()
            if (fail) throw AccountFailure(409, "Already linked to another account")
            return result
        }
        override suspend fun cancelApple(state: String, verifier: String) { cancelled = true }
        override suspend fun loginGoogle(identityToken: String) = auth
        override suspend fun me(token: String) = auth.user
        override suspend fun providers(token: String) = setOf("apple", "google")
        override suspend fun linkGoogle(token: String, identityToken: String) = setOf("apple", "google")
        override suspend fun logout(token: String) { loggedOut += token }
        override suspend fun delete(token: String) {}
    }
    @Test fun appleLoginStoresTheSameAccountAndClearsItsHandoff() = runTest {
        val api = Api(); val store = Store(); val pending = MemoryApplePendingStore()
        val session = AccountSession(api, store, pending)
        var opened = false
        session.signInApple(null) { url ->
            opened = true
            assertTrue(AppleBrowserProof.isAuthorizationUrl(url))
            assertEquals(api.challenge, AppleBrowserProof.challenge(pending.read()!!.verifier))
        }
        assertTrue(opened)
        assertEquals("apple-session", store.token)
        assertEquals("same-user", session.state.value.user?.id)
        assertNull(pending.read())
        assertNull(api.startSession)
        assertFalse(session.state.value.busy)
    }
    @Test fun linkingUsesTheExistingSessionWithoutReplacingIt() = runTest {
        val api = Api().apply { result = AppleBrowserResult("complete", providers = setOf("apple", "google")) }
        val store = Store("google-session"); val session = AccountSession(api, store)
        session.signInApple(requireNotNull(session.state.value.sessionId)) {}
        assertEquals("google-session", api.startSession)
        assertEquals("google-session", api.finishSession)
        assertEquals("google-session", store.token)
        assertEquals(setOf("apple", "google"), session.state.value.providers)
    }
    @Test fun oldAppleLinkButtonCannotOpenAnAuthorizationForTheReplacement() = runTest {
        val api = Api()
        val session = AccountSession(api, Store("first"))
        val original = requireNotNull(session.state.value.sessionId)
        session.signOut(session.state.value.sessionId)
        session.signInGoogle { "second-proof" }
        session.signInApple(original) { fail("Old Apple authorization opened") }
        assertNull(api.challenge)
        assertEquals(0, api.finishCount)
        api.result = AppleBrowserResult("complete", providers = setOf("apple", "google"))
        session.signInApple(requireNotNull(session.state.value.sessionId)) {}
        assertEquals("apple-session", api.startSession)
        assertEquals(1, api.finishCount)
    }

    @Test fun linkConflictPreservesTheOriginalAccount() = runTest {
        val api = Api().apply { fail = true }; val store = Store("google-session")
        val session = AccountSession(api, store)
        session.signInApple(requireNotNull(session.state.value.sessionId)) {}
        assertEquals("google-session", store.token)
        assertTrue(session.state.value.signedIn)
        assertFalse(session.state.value.applePending)
        assertEquals("Already linked to another account", session.state.value.error)
    }
    @Test fun providerCancellationCreatesNoSession() = runTest {
        val api = Api().apply { result = AppleBrowserResult("cancelled") }
        val store = Store(); val session = AccountSession(api, store)
        session.signInApple(null) {}
        assertNull(store.token)
        assertNull(session.state.value.error)
        assertFalse(session.state.value.applePending)
    }
    @Test fun cancellationPreventsALateCompletionRestoringASession() = runTest {
        val api = Api().apply { gate = CompletableDeferred() }; val store = Store()
        val pending = MemoryApplePendingStore(); val session = AccountSession(api, store, pending)
        val task = launch { session.signInApple(null) {} }; runCurrent()
        assertTrue(session.state.value.applePending)
        session.cancelApple(requireNotNull(session.state.value.appleAttempt)); api.gate!!.complete(Unit); task.join()
        assertNull(store.token)
        assertNull(pending.read())
        assertFalse(session.state.value.signedIn)
        assertTrue(api.cancelled)
        assertEquals(listOf("apple-session"), api.loggedOut)
    }
    @Test fun returningAfterProcessDeathResumesTheEncryptedHandoff() = runTest {
        val api = Api(); val store = Store(); val pending = MemoryApplePendingStore()
        pending.write(ApplePending("s".repeat(43), "v".repeat(43), "https://appleid.apple.com/auth/authorize", 1000, null))
        val restored = AccountSession(api, store, pending, now = { 0 })
        assertTrue(restored.state.value.applePending)
        restored.resumeApple(requireNotNull(restored.state.value.appleAttempt))
        assertEquals("apple-session", store.token)
        assertNull(pending.read())
    }
    @Test fun connectionFailureRetainsProofAndResumesWithoutAnotherAppleAuthorization() = runTest {
        val api = Api().apply { connectionFailure = true }
        val store = Store(); val pending = MemoryApplePendingStore()
        val session = AccountSession(api, store, pending)
        var browserOpens = 0
        session.signInApple(null) { browserOpens++ }
        val proof = pending.read()
        assertNotNull(proof)
        assertFalse(session.state.value.busy)
        assertTrue(session.state.value.applePending)
        assertEquals("Could not connect to Magpie. Check your connection, then try again.", session.state.value.error)
        api.connectionFailure = false
        session.resumeApple(requireNotNull(session.state.value.appleAttempt))
        assertEquals(1, browserOpens)
        assertEquals(2, api.finishCount)
        assertEquals("apple-session", store.token)
        assertNull(pending.read())
        assertNull(session.state.value.error)
    }
    @Test fun cancelledAttemptsControlsCannotOpenCheckOrCancelTheReplacement() = runTest {
        val api = Api().apply { connectionFailure = true }
        val store = Store()
        val pending = MemoryApplePendingStore()
        val session = AccountSession(api, store, pending)
        session.signInApple(null) {}
        var reopened = 0
        val first = requireNotNull(session.state.value.appleAttempt)
        val staleOpen = { session.reopenApple(first) { reopened++ } }
        val staleCheck: suspend () -> Unit = { session.resumeApple(first) }
        val staleCancel: suspend () -> Unit = { session.cancelApple(first) }
        staleCancel()
        session.signInApple(null) {}
        val replacement = requireNotNull(pending.read())
        api.cancelled = false
        val attempts = api.finishCount
        staleOpen()
        staleCheck()
        staleCancel()
        assertEquals(0, reopened)
        assertEquals(attempts, api.finishCount)
        assertFalse(api.cancelled)
        assertEquals(replacement, pending.read())
        val restored = AccountSession(api, store, pending)
        restored.reopenApple(replacement.attemptId) { reopened++ }
        api.connectionFailure = false
        restored.resumeApple(requireNotNull(restored.state.value.appleAttempt))
        assertEquals(1, reopened)
        assertEquals(attempts + 1, api.finishCount)
        assertEquals("apple-session", store.token)
    }

    @Test fun restoredLinkCannotAttachToADifferentSession() = runTest {
        val api = Api(); val pending = MemoryApplePendingStore()
        pending.write(ApplePending("s".repeat(43), "v".repeat(43), "https://appleid.apple.com/auth/authorize", 1000,
            AppleBrowserProof.challenge("old-session")))
        val store = Store("new-session"); val session = AccountSession(api, store, pending, now = { 0 })
        session.resumeApple(requireNotNull(session.state.value.appleAttempt))
        assertEquals(0, api.finishCount)
        assertEquals("new-session", store.token)
        assertNull(pending.read())
        assertNotNull(session.state.value.error)
    }
    @Test fun expiredAttemptDoesNotContactTheCompletionEndpoint() = runTest {
        val api = Api(); val pending = MemoryApplePendingStore()
        pending.write(ApplePending("s".repeat(43), "v".repeat(43), "https://appleid.apple.com/auth/authorize", 1000, null))
        val session = AccountSession(api, Store(), pending, now = { 1001 })
        session.resumeApple(requireNotNull(session.state.value.appleAttempt))
        assertEquals(0, api.finishCount)
        assertFalse(session.state.value.applePending)
        assertNotNull(session.state.value.error)
    }
    @Test fun untrustedBrowserUrlsAreRejected() {
        for (url in listOf("http://appleid.apple.com/auth/authorize", "https://appleid.apple.com.evil.test/auth/authorize",
            "https://evil.test/auth/authorize", "https://user@appleid.apple.com/auth/authorize")) {
            assertFalse(AppleBrowserProof.isAuthorizationUrl(url))
        }
        assertTrue(AppleBrowserProof.isAuthorizationUrl("https://appleid.apple.com/auth/authorize?nonce=abc"))
    }
}
