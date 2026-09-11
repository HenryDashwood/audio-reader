package com.henrydashwood.magpie.auth

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.Image
import androidx.compose.ui.res.painterResource
import com.henrydashwood.magpie.R
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.*
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel

@Composable
fun AccountScreen(onBack: () -> Unit, model: AccountModel = viewModel()) {
    val state by model.state.collectAsStateWithLifecycle()
    val context = LocalContext.current
    AccountContent(state, model.configured, onBack, { model.signIn(context) }, { model.link(context) },
        model::refresh, model::signOut, model::delete, appleConfigured = model.appleConfigured,
        signInApple = { model.apple(context, false) }, linkApple = { model.apple(context, true) },
        cancelApple = model::cancelApple, resumeApple = model::resumeApple, reopenApple = { model.reopenApple(context) })
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AccountContent(state: AccountState, configured: Boolean, onBack: () -> Unit,
    signIn: () -> Unit, linkGoogle: () -> Unit, refresh: () -> Unit, signOut: () -> Unit, delete: () -> Unit,
    appleConfigured: Boolean = false, signInApple: () -> Unit = {}, linkApple: () -> Unit = {},
    cancelApple: () -> Unit = {}, resumeApple: () -> Unit = {}, reopenApple: () -> Unit = {}) {
    var confirmingDelete by rememberSaveable { mutableStateOf(false) }
    Scaffold(topBar = {
        TopAppBar(title = { Text("Sign-in Methods") }, navigationIcon = {
            IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Rounded.ArrowBack, "Back") }
        })
    }) { padding ->
        LazyColumn(Modifier.fillMaxSize().padding(padding).padding(horizontal = 16.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp), contentPadding = PaddingValues(vertical = 16.dp)) {
            item { Text("Android preview · Sample library", style = MaterialTheme.typography.titleMedium) }
            item { Text("Signing in connects your account. The library shown in this preview still contains samples and does not change your saved library or listening progress.") }
            if (!state.signedIn) {
                item { Text("Sign in to Magpie", Modifier.semantics { heading() }, style = MaterialTheme.typography.titleLarge) }
                item { Text("Already use Magpie on iOS? Sign in with the same Apple account to keep your account together.") }
                item { AppleSignInButton(appleConfigured && !state.busy && !state.applePending, signInApple) }
                item { OutlinedButton(onClick = signIn, enabled = configured && !state.busy && !state.applePending,
                    modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp)) { Image(painterResource(R.drawable.google_g), null, Modifier.size(20.dp)); Spacer(Modifier.width(12.dp)); Text("Sign in with Google") } }
            } else {
                item { Text(state.user?.displayName ?: "Signed in", Modifier.semantics { heading() }, style = MaterialTheme.typography.titleLarge) }
                item { Text("Connect Apple and Google to use either for the same account. Matching email addresses alone do not connect accounts.") }
                if (state.providers == null) {
                    item { Button(onClick = refresh, enabled = !state.busy) { Text("Load sign-in methods") } }
                } else {
                    item { Text(if ("apple" in state.providers) "Apple · Connected" else "Apple · Not connected") }
                    item { Text(if ("google" in state.providers) "Google · Connected" else "Google · Not connected") }
                    if ("apple" !in state.providers) item {
                        Text("Connect your Apple account")
                        AppleSignInButton(appleConfigured && !state.busy && !state.applePending, linkApple)
                    }
                    if ("google" !in state.providers) item {
                        Text("Connect your Google account")
                        OutlinedButton(onClick = linkGoogle, enabled = configured && !state.busy && !state.applePending,
                            modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp)) { Image(painterResource(R.drawable.google_g), null, Modifier.size(20.dp)); Spacer(Modifier.width(12.dp)); Text("Sign in with Google") }
                    }
                }
                item { TextButton(onClick = signOut, enabled = !state.busy) { Text("Sign Out") } }
                item { TextButton(onClick = { confirmingDelete = true }, enabled = !state.busy) {
                    Text("Delete Account", color = MaterialTheme.colorScheme.error)
                } }
            }
            if (state.applePending) item {
                Text("Finish signing in with Apple in your browser, then return to Magpie.")
                TextButton(onClick = reopenApple) { Text("Open Apple sign-in") }
                if (!state.busy) TextButton(onClick = resumeApple) { Text("Check Again") }
                TextButton(onClick = cancelApple) { Text("Cancel Apple sign-in") }
            }
            if (!appleConfigured) item { Text("Apple sign-in is not available in this build yet.") }
            if (!configured) item { Text("Google sign-in is not available in this build yet.") }
            if (state.busy) item { Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                CircularProgressIndicator(Modifier.size(24.dp)); Text("Updating account…", Modifier.semantics { liveRegion = LiveRegionMode.Polite })
            } }
            state.error?.let { error -> item { Text(error, color = MaterialTheme.colorScheme.error,
                modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite }) } }
        }
    }
    if (confirmingDelete) AlertDialog(onDismissRequest = { confirmingDelete = false },
        title = { Text("Delete your account?") },
        text = { Text("This permanently deletes your Magpie account and library on every device, including iOS, and removes all linked sign-in methods. It cannot be undone.") },
        confirmButton = { TextButton(onClick = { confirmingDelete = false; delete() }) { Text("Delete Account") } },
        dismissButton = { TextButton(onClick = { confirmingDelete = false }) { Text("Cancel") } })
}


@Composable
private fun AppleSignInButton(enabled: Boolean, action: () -> Unit) {
    Button(onClick = action, enabled = enabled, modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp),
        colors = ButtonDefaults.buttonColors(containerColor = Color.Black, contentColor = Color.White,
            disabledContainerColor = Color.Black, disabledContentColor = Color.White.copy(alpha = 0.38f))) {
        // Apple's supplied logo image includes padding and a black background.
        Image(painterResource(R.drawable.apple_sign_in_logo), null, Modifier.size(40.dp),
            alpha = if (enabled) 1f else 0.38f)
        Spacer(Modifier.width(12.dp))
        Text("Sign in with Apple")
    }
}
