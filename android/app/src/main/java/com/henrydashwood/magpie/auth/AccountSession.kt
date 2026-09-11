package com.henrydashwood.magpie.auth

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.io.IOException

// Called from the main dispatcher. The generation prevents late provider/network replies
// from restoring a signed-out account or attaching credentials to a different session.
data class AccountState(val signedIn: Boolean = false, val user: AccountUser? = null,
    val providers: Set<String>? = null, val busy: Boolean = false, val error: String? = null,
    val applePending: Boolean = false)

class AccountSession(private val api: AccountApi, private val store: AccountTokenStore,
    private val appleStore: ApplePendingStore = MemoryApplePendingStore(),
    private val now: () -> Long = System::currentTimeMillis) {
    private var token: String? = store.read()
    private val mutableToken = MutableStateFlow(token)
    internal val accessToken = mutableToken.asStateFlow()
    private var generation = 0
    private val mutableState = MutableStateFlow(AccountState(signedIn = token != null, applePending = appleStore.read() != null))
    val state = mutableState.asStateFlow()

    suspend fun refresh() {
        val current = token ?: return
        operation {
            val user = api.me(current)
            val providers = api.providers(current)
            AccountState(signedIn = true, user = user, providers = providers, applePending = appleStore.read() != null)
        }
    }
    suspend fun signInGoogle(authorize: suspend () -> String) {
        if (token != null || state.value.applePending) return
        operation {
            val version = generation
            val credential = authorize()
            if (version != generation) return@operation null
            val response = api.loginGoogle(credential)
            if (version != generation) { runCatching { api.logout(response.token) }; return@operation null }
            try { store.write(response.token) }
            catch (failure: Exception) { runCatching { api.logout(response.token) }; throw failure }
            token = response.token
            mutableToken.value = token
            // /me/identities can be retried independently without losing a valid login.
            AccountState(signedIn = true, user = response.user)
        }
        if (token != null) refresh()
    }
    suspend fun linkGoogle(authorize: suspend () -> String) {
        if (state.value.applePending) return
        val current = token ?: return
        operation {
            val version = generation
            val credential = authorize()
            if (version != generation || current != token) return@operation null
            val providers = api.linkGoogle(current, credential)
            state.value.copy(providers = providers, error = null)
        }
    }
    suspend fun signInApple(link: Boolean, openBrowser: (String) -> Unit) {
        if (link != (token != null) || state.value.applePending) return
        operation {
            val version = generation
            val current = if (link) token else null
            val verifier = AppleBrowserProof.verifier()
            val started = api.startApple(AppleBrowserProof.challenge(verifier), current)
            if (version != generation) { runCatching { api.cancelApple(started.state, verifier) }; return@operation null }
            require(AppleBrowserProof.isAuthorizationUrl(started.authorizationUrl))
            val pending = ApplePending(started.state, verifier, started.authorizationUrl,
                now() + started.expiresIn.coerceIn(1, 300) * 1000L, current?.let(AppleBrowserProof::challenge))
            appleStore.write(pending)
            mutableState.value = state.value.copy(applePending = true)
            try { openBrowser(pending.authorizationUrl) }
            catch (failure: Exception) { appleStore.clear(); runCatching { api.cancelApple(pending.state, pending.verifier) }; throw failure }
            awaitApple(pending, version)
        }
    }

    suspend fun resumeApple() {
        val pending = appleStore.read() ?: return
        operation { awaitApple(pending, generation) }
    }

    fun reopenApple(openBrowser: (String) -> Unit) {
        try { appleStore.read()?.let { openBrowser(it.authorizationUrl) } }
        catch (failure: Exception) {
            mutableState.value = state.value.copy(error = (failure as? AccountFailure)?.message
                ?: "Apple sign-in could not be opened. Please try again.")
        }
    }

    suspend fun cancelApple() {
        val pending = appleStore.read() ?: return
        // Forget the proof first; late browser returns cannot finish this attempt.
        appleStore.clear()
        generation++
        mutableState.value = state.value.copy(busy = false, applePending = false, error = null)
        runCatching { api.cancelApple(pending.state, pending.verifier) }
    }

    private suspend fun awaitApple(pending: ApplePending, version: Int): AccountState? {
        if (pending.sessionHash != token?.let(AppleBrowserProof::challenge)) {
            appleStore.clear()
            throw AccountFailure(403, "Return to the account where you started connecting Apple.")
        }
        while (version == generation) {
            if (now() >= pending.expiresAt) {
                appleStore.clear()
                throw AccountFailure(410, "This Apple sign-in has expired. Please try again.")
            }
            val response = api.completeApple(pending.state, pending.verifier, token)
            if (version != generation) {
                response.auth?.let { runCatching { api.logout(it.token) } }
                return null
            }
            when (response.status) {
                "pending" -> delay(1500)
                "cancelled" -> {
                    appleStore.clear()
                    return state.value.copy(applePending = false, error = null)
                }
                "complete" -> {
                    if (pending.sessionHash == null) {
                        val auth = response.auth ?: throw AccountFailure(0, "Apple sign-in did not finish. Please try again.")
                        require(auth.token.isNotBlank())
                        try { store.write(auth.token) }
                        catch (failure: Exception) { runCatching { api.logout(auth.token) }; throw failure }
                        token = auth.token
                        mutableToken.value = token
                        appleStore.clear()
                        return AccountState(signedIn = true, user = auth.user)
                    }
                    val providers = response.providers ?: throw AccountFailure(0, "Apple could not be connected. Please try again.")
                    appleStore.clear()
                    return state.value.copy(providers = providers, applePending = false, error = null)
                }
                else -> throw AccountFailure(0, "Apple sign-in did not finish. Please try again.")
            }
        }
        return null
    }

    suspend fun signOut() {
        val current = token
        try { forget() }
        catch (_: Exception) {
            mutableState.value = state.value.copy(error = "Sign-out could not be saved on this device. Please try again.")
            return
        }
        if (current != null) runCatching { api.logout(current) }
    }
    suspend fun delete() {
        val current = token ?: return
        operation {
            val version = generation
            api.delete(current)
            if (version == generation) forget()
            null
        }
    }
    internal fun rejectToken(rejected: String) {
        // A late 401 from an old request cannot sign out a newer session.
        if (token != rejected) return
        forget()
        mutableState.value = state.value.copy(error = "Please sign in again.")
    }
    private fun forget() {
        // If durable removal fails, leave an actionable error instead of claiming sign-out.
        store.clear()
        appleStore.clear()
        generation++
        token = null
        mutableToken.value = null
        mutableState.value = AccountState()
    }
    private suspend fun operation(work: suspend () -> AccountState?) {
        if (state.value.busy) return
        val version = generation
        mutableState.value = state.value.copy(busy = true, error = null)
        try {
            val updated = work()
            if (version == generation && updated != null) mutableState.value = updated
        } catch (cancelled: CancellationException) { throw cancelled
        } catch (failure: Exception) {
            if (version == generation) {
                if (failure is AccountFailure && failure.status == 401 && token != null) forget()
                // Network failures retain the encrypted handoff for a foreground or manual retry.
                if (failure is AccountFailure && failure.status in setOf(400, 403, 409, 410)) appleStore.clear()
                mutableState.value = state.value.copy(applePending = appleStore.read() != null,
                    error = when (failure) {
                        is AccountFailure -> failure.message
                        is IOException -> "Could not connect to Magpie. Check your connection, then try again."
                        else -> "The account request did not work. Please try again."
                    })
            }
        } finally {
            if (version == generation) mutableState.value = state.value.copy(busy = false)
        }
    }
}
