package com.henrydashwood.magpie.auth

import android.content.Context
import androidx.credentials.ClearCredentialStateRequest
import androidx.credentials.CredentialManager
import androidx.credentials.CustomCredential
import androidx.credentials.GetCredentialRequest
import androidx.credentials.exceptions.GetCredentialCancellationException
import com.google.android.libraries.identity.googleid.GetSignInWithGoogleOption
import com.google.android.libraries.identity.googleid.GoogleIdTokenCredential
import kotlinx.coroutines.CancellationException

class GoogleAuthorization(context: Context, private val serverClientId: String) {
    private val manager = CredentialManager.create(context)
    suspend fun identityToken(activity: Context): String {
        try {
            val request = GetCredentialRequest.Builder().addCredentialOption(
                GetSignInWithGoogleOption.Builder(serverClientId).build()).build()
            val credential = manager.getCredential(activity, request).credential
            if (credential !is CustomCredential || credential.type != GoogleIdTokenCredential.TYPE_GOOGLE_ID_TOKEN_CREDENTIAL) {
                throw AccountFailure(0, "Google sign-in did not work. Please try again.")
            }
            return GoogleIdTokenCredential.createFrom(credential.data).idToken
        } catch (_: GetCredentialCancellationException) { throw CancellationException("Sign-in cancelled") }
    }
    suspend fun clear() { runCatching { manager.clearCredentialState(ClearCredentialStateRequest()) } }
}
