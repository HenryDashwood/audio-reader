package com.henrydashwood.magpie.auth

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runTest
import org.junit.Assert.*
import org.junit.Test

class AccountSessionTest {
    private class Store(var token: String? = null) : AccountTokenStore {
        var failWrites = false
        override fun read() = token
        override fun write(token: String) { check(!failWrites); this.token = token }
        override fun clear() { token = null }
    }
    private class Api : AccountApi {
        var failure: AccountFailure? = null
        val user = AccountUser("same-account", null)
        var linked = setOf("apple", "google")
        var loginCount = 0
        var linkCount = 0
        val loggedOut = mutableListOf<String>()
        var loginGate: CompletableDeferred<Unit>? = null
        override suspend fun loginGoogle(identityToken: String): AccountLogin {
            loginCount++
            loginGate?.await()
            failure?.let { throw it }
            return AccountLogin("session", user)
        }
        override suspend fun me(token: String): AccountUser { failure?.let { throw it }; return user }
        override suspend fun providers(token: String) = linked
        override suspend fun linkGoogle(token: String, identityToken: String): Set<String> {
            linkCount++; failure?.let { throw it }; return linked
        }
        override suspend fun logout(token: String) { loggedOut += token }
        override suspend fun delete(token: String) { failure?.let { throw it } }
    }
    @Test fun googleLoginRestoresSameUserAndLinkedProviders() = runTest {
        val api = Api(); val store = Store(); val session = AccountSession(api, store)
        session.signInGoogle { "proof" }
        assertEquals("session", store.token)
        assertEquals("same-account", session.state.value.user?.id)
        assertEquals(setOf("apple", "google"), session.state.value.providers)
        assertFalse(session.state.value.busy)
    }
    @Test fun explicitLinkPreservesSessionAndConflictDoesNotSignOut() = runTest {
        val api = Api(); val store = Store("original"); val session = AccountSession(api, store)
        api.linked = setOf("apple"); session.refresh()
        api.failure = AccountFailure(409, "Already linked to another account")
        session.linkGoogle { "proof" }
        assertTrue(session.state.value.signedIn)
        assertEquals("original", store.token)
        assertEquals(setOf("apple"), session.state.value.providers)
        assertEquals("Already linked to another account", session.state.value.error)
        api.failure = null; api.linked = setOf("apple", "google"); session.linkGoogle { "proof" }
        assertEquals(setOf("apple", "google"), session.state.value.providers)
        assertEquals("original", store.token)
        assertEquals(0, api.loginCount)
    }
    @Test fun cancellingDoesNotCreateAnAccountOrDisplayAnError() = runTest {
        val api = Api(); val session = AccountSession(api, Store())
        try { session.signInGoogle { throw CancellationException() } } catch (_: CancellationException) { }
        assertEquals(0, api.loginCount)
        assertFalse(session.state.value.signedIn)
        assertFalse(session.state.value.busy)
        assertNull(session.state.value.error)
    }
    @Test fun signOutWhileProviderSheetIsOpenPreventsLateLogin() = runTest {
        val api = Api(); val session = AccountSession(api, Store())
        val gate = CompletableDeferred<String>(); val started = CompletableDeferred<Unit>()
        val pending = launch { session.signInGoogle { started.complete(Unit); gate.await() } }
        started.await(); session.signOut(); gate.complete("proof"); pending.join()
        assertEquals(0, api.loginCount)
        assertFalse(session.state.value.signedIn)
    }
    @Test fun signOutDuringExchangeRevokesTheLateSession() = runTest {
        val api = Api(); val store = Store(); val session = AccountSession(api, store)
        val started = CompletableDeferred<Unit>(); api.loginGate = CompletableDeferred()
        val pending = launch { session.signInGoogle { started.complete(Unit); "proof" } }
        started.await(); session.signOut(); api.loginGate!!.complete(Unit); pending.join()
        assertFalse(session.state.value.signedIn)
        assertNull(store.token)
        assertEquals(listOf("session"), api.loggedOut)
    }
    @Test fun signOutDuringGoogleLinkCannotAttachCredentialsToAnotherSession() = runTest {
        val api = Api(); val session = AccountSession(api, Store("original"))
        val gate = CompletableDeferred<String>(); val started = CompletableDeferred<Unit>()
        val pending = launch { session.linkGoogle { started.complete(Unit); gate.await() } }
        started.await(); session.signOut(); gate.complete("proof"); pending.join()
        assertEquals(0, api.linkCount)
        assertFalse(session.state.value.signedIn)
    }
    @Test fun offlineRestorePreservesSessionButRevocationClearsIt() = runTest {
        val api = Api(); val store = Store("session"); val session = AccountSession(api, store)
        api.failure = AccountFailure(503, "Offline"); session.refresh()
        assertTrue(session.state.value.signedIn)
        assertEquals("session", store.token)
        api.failure = AccountFailure(401, "Sign in again"); session.refresh()
        assertFalse(session.state.value.signedIn)
        assertNull(store.token)
    }
    @Test fun deletionFailurePreservesAccountAndSuccessClearsIt() = runTest {
        val api = Api(); val store = Store("session"); val session = AccountSession(api, store)
        api.failure = AccountFailure(503, "Try again"); session.delete()
        assertTrue(session.state.value.signedIn)
        assertEquals("session", store.token)
        api.failure = null; session.delete()
        assertFalse(session.state.value.signedIn)
        assertNull(store.token)
    }
    @Test fun failedSecureStorageDoesNotClaimSuccessfulLogin() = runTest {
        val api = Api(); val store = Store().apply { failWrites = true }; val session = AccountSession(api, store)
        session.signInGoogle { "proof" }
        assertFalse(session.state.value.signedIn)
        assertNotNull(session.state.value.error)
        assertEquals(listOf("session"), api.loggedOut)
    }
}
