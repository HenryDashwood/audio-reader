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
        if (state.value.applePending) resumeApple() else refresh()
    } }
    fun apple(context: Context, link: Boolean) {
        if (!appleConfigured || state.value.busy) return
        appleJob = viewModelScope.launch {
            session.signInApple(link) { openAppleBrowser(context, it) }
            if (state.value.signedIn && state.value.error == null) session.refresh()
        }
    }
    fun resumeApple() {
        if (!state.value.applePending) return
        val previous = appleJob
        if (state.value.busy && previous?.isActive != true) return
        appleJob = viewModelScope.launch {
            // Do not race one-time completion requests. If the background check
            // is still unwinding, recover after it finishes instead of dropping
            // the browser-return event while busy.
            previous?.join()
            session.resumeApple()
            if (state.value.signedIn && state.value.error == null) session.refresh()
        }
    }
    fun reopenApple(context: Context) { session.reopenApple { openAppleBrowser(context, it) } }
    fun cancelApple() { appleJob?.cancel(); viewModelScope.launch { session.cancelApple() } }
    fun refresh() { viewModelScope.launch { session.refresh() } }
    fun signIn(context: Context) { if (configured) viewModelScope.launch { session.signInGoogle { google.identityToken(context) } } }
    fun link(context: Context) { if (configured) viewModelScope.launch { session.linkGoogle { google.identityToken(context) } } }
    fun signOut() { viewModelScope.launch { session.signOut(); google.clear() } }
    fun delete() { viewModelScope.launch { session.delete(); if (!state.value.signedIn) google.clear() } }
}
