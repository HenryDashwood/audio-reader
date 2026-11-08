package com.henrydashwood.magpie.auth

import android.app.Application
import android.content.Context
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.henrydashwood.magpie.BuildConfig
import kotlinx.coroutines.launch
import kotlinx.coroutines.Job

class AccountModel(application: Application) : AndroidViewModel(application) {
    val configured = BuildConfig.ACCOUNT_API_URL.isNotBlank() &&
        BuildConfig.GOOGLE_SERVER_CLIENT_ID.endsWith(".apps.googleusercontent.com")
    private val google = GoogleAuthorization(application, BuildConfig.GOOGLE_SERVER_CLIENT_ID)
    val appleConfigured = BuildConfig.ACCOUNT_API_URL.isNotBlank()
    private var appleJob: Job? = null
    private val session = (application as com.henrydashwood.magpie.MagpieApplication).accounts
    val state = session.state
    init { if (appleConfigured) {
        val attempt = state.value.appleAttempt
        if (attempt != null) resumeApple(attempt) else refresh()
    } }
    fun apple(context: Context, expectedSession: String?) {
        if (!appleConfigured || state.value.busy || expectedSession != state.value.sessionId) return
        appleJob = viewModelScope.launch {
            session.signInApple(expectedSession) { openAppleBrowser(context, it) }
            if (state.value.signedIn && state.value.error == null) session.refresh()
        }
    }
    fun resumeApple(attempt: String) {
        if (attempt != state.value.appleAttempt) return
        val previous = appleJob
        if (state.value.busy && previous?.isActive != true) return
        appleJob = viewModelScope.launch {
            // Do not race one-time completion requests. If the background check
            // is still unwinding, recover after it finishes instead of dropping
            // the browser-return event while busy.
            previous?.join()
            if (attempt != state.value.appleAttempt) return@launch
            session.resumeApple(attempt)
            if (state.value.signedIn && state.value.error == null) session.refresh()
        }
    }
    fun reopenApple(context: Context, attempt: String) { session.reopenApple(attempt) { openAppleBrowser(context, it) } }
    fun cancelApple(attempt: String) {
        if (state.value.appleAttempt != attempt) return
        appleJob?.cancel()
        viewModelScope.launch { session.cancelApple(attempt) }
    }
    fun refresh() { viewModelScope.launch { session.refresh() } }
    fun signIn(context: Context) { if (configured) viewModelScope.launch { session.signInGoogle { google.identityToken(context) } } }
    fun link(context: Context, expectedSession: String) { if (configured) viewModelScope.launch { session.linkGoogle(expectedSession) { google.identityToken(context) } } }
    fun signOut(expectedSession: String) {
        viewModelScope.launch { if (session.signOut(expectedSession)) google.clear() }
    }
    fun delete(confirmedSession: String) { viewModelScope.launch { session.delete(confirmedSession); if (!state.value.signedIn) google.clear() } }
}
