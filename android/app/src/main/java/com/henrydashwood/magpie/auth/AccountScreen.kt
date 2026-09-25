package com.henrydashwood.magpie.auth

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.Image
import androidx.compose.ui.res.painterResource
import com.henrydashwood.magpie.R
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.CheckCircleOutline
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.*
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.compose.LifecycleEventEffect
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.viewmodel.compose.viewModel

@Composable
fun AccountScreen(onBack: () -> Unit, model: AccountModel = viewModel()) {
    val state by model.state.collectAsStateWithLifecycle()
    val context = LocalContext.current
    // Loads the connected providers on arrival, as iOS does.
    LaunchedEffect(state.signedIn) { if (state.signedIn && state.providers == null) model.refresh() }
    AccountContent(state, model.configured, onBack, { model.signIn(context) }, { model.link(context) },
        model::refresh, appleConfigured = model.appleConfigured,
        signInApple = { model.apple(context, false) }, linkApple = { model.apple(context, true) },
        cancelApple = model::cancelApple, resumeApple = model::resumeApple, reopenApple = { model.reopenApple(context) })
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AccountContent(state: AccountState, configured: Boolean, onBack: () -> Unit,
    signIn: () -> Unit, linkGoogle: () -> Unit, refresh: () -> Unit,
    appleConfigured: Boolean = false, signInApple: () -> Unit = {}, linkApple: () -> Unit = {},
    cancelApple: () -> Unit = {}, resumeApple: () -> Unit = {}, reopenApple: () -> Unit = {}) {
    // A Custom Tab can outlive a failed background request. Check the retained
    // proof when this screen becomes active again, including a browser return.
    LifecycleEventEffect(Lifecycle.Event.ON_RESUME) {
        if (state.applePending) resumeApple()
    }
    Scaffold(topBar = {
        TopAppBar(title = { Text("Sign-in Methods") }, navigationIcon = {
            IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Rounded.ArrowBack, "Back") }
        })
    }) { padding ->
        LazyColumn(Modifier.fillMaxSize().padding(padding).padding(horizontal = 16.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp), contentPadding = PaddingValues(vertical = 16.dp)) {
            if (!state.signedIn) {
                item { Text("Android preview · Sample library", style = MaterialTheme.typography.titleMedium) }
                item { Text("Sign in to load your subscriptions and saved articles. Until then, this preview uses a separate sample library.") }
                item { Text("Sign in to Magpie", Modifier.semantics { heading() }, style = MaterialTheme.typography.titleLarge) }
                item { Text("Already use Magpie on iOS? Sign in with the same Apple account to keep your account together.") }
                item { AppleSignInButton(appleConfigured && !state.busy && !state.applePending, action = signInApple) }
                item { OutlinedButton(onClick = signIn, enabled = configured && !state.busy && !state.applePending,
                    modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp)) { Image(painterResource(R.drawable.google_g), null, Modifier.size(20.dp)); Spacer(Modifier.width(12.dp)); Text("Sign in with Google") } }
            } else {
                // As on iOS (SignInMethodsView): what connecting does, then one section per provider.
                item { Text("Connect Apple and Google to use either to sign in. If both already have Magpie accounts, connecting combines their subscriptions, saved articles, and listening progress.") }
                val providers = state.providers
                if (providers == null) {
                    if (state.error == null) item { Row(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
                        CircularProgressIndicator(Modifier.size(24.dp)); Text("Loading sign-in methods…") } }
                    else item { TextButton(onClick = refresh, enabled = !state.busy) { Text("Try Again") } }
                } else {
                    item { Text("Apple", style = MaterialTheme.typography.titleSmall, modifier = Modifier.semantics { heading() }) }
                    if ("apple" in providers) item { ConnectedLabel() } else item {
                        Text("Connect your Apple account")
                        AppleSignInButton(appleConfigured && !state.busy && !state.applePending, "Continue with Apple", linkApple)
                    }
                    item { Text("Google", style = MaterialTheme.typography.titleSmall, modifier = Modifier.semantics { heading() }) }
                    if ("google" in providers) item { ConnectedLabel() } else item {
                        Text("Connect your Google account")
                        OutlinedButton(onClick = linkGoogle, enabled = configured && !state.busy && !state.applePending,
                            modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp)) { Image(painterResource(R.drawable.google_g), null, Modifier.size(20.dp)); Spacer(Modifier.width(12.dp)); Text("Continue with Google") }
                    }
                }
                item { Text("Connecting requires signing in with the additional provider. Matching email addresses alone do not connect accounts. After combining accounts, review AI Data Sharing in Settings. Devices signed in to the other account will need to sign in again.",
                    style = MaterialTheme.typography.bodySmall) }
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
}


@Composable
internal fun AppleSignInButton(enabled: Boolean, label: String = "Sign in with Apple", action: () -> Unit) {
    Button(onClick = action, enabled = enabled, modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp),
        colors = ButtonDefaults.buttonColors(containerColor = Color.Black, contentColor = Color.White,
            disabledContainerColor = Color.Black, disabledContentColor = Color.White.copy(alpha = 0.38f))) {
        // Apple's supplied logo image includes padding and a black background.
        Image(painterResource(R.drawable.apple_sign_in_logo), null, Modifier.size(40.dp),
            alpha = if (enabled) 1f else 0.38f)
        Spacer(Modifier.width(12.dp))
        Text(label)
    }
}

@Composable
private fun ConnectedLabel() {
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
        Icon(androidx.compose.material.icons.Icons.Rounded.CheckCircleOutline, null, tint = MaterialTheme.colorScheme.primary)
        Text("Connected")
    }
}
