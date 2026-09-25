package com.henrydashwood.magpie.auth

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.*
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LifecycleEventEffect
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import com.henrydashwood.magpie.R

/** The gate shown until a session exists, as on iOS (SignInView.swift). */
@Composable
fun SignInScreen(model: AccountModel = viewModel()) {
    val state by model.state.collectAsStateWithLifecycle()
    val context = LocalContext.current
    // A browser return from Apple sign-in resumes here; the proof is retained across process death.
    LifecycleEventEffect(Lifecycle.Event.ON_RESUME) { if (state.applePending) model.resumeApple() }
    Surface(Modifier.fillMaxSize()) {
        Column(Modifier.fillMaxSize().systemBarsPadding().verticalScroll(rememberScrollState()).padding(horizontal = 32.dp),
            horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(24.dp)) {
            Spacer(Modifier.height(48.dp))
            Image(painterResource(R.drawable.magpie_mark), null, Modifier.size(120.dp)
                .background(Color(0xFF0E1114), CircleShape).padding(4.dp))
            Text("Magpie", style = MaterialTheme.typography.displaySmall, fontWeight = FontWeight.Bold,
                modifier = Modifier.semantics { heading() })
            Text("Sign in so your shows and listening positions follow you.", style = MaterialTheme.typography.titleMedium,
                textAlign = TextAlign.Center)
            Spacer(Modifier.height(24.dp))
            state.error?.let { Text(it, color = MaterialTheme.colorScheme.error, textAlign = TextAlign.Center,
                modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite }) }
            Column(Modifier.widthIn(max = 420.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                AppleSignInButton(model.appleConfigured && !state.busy && !state.applePending) { model.apple(context, false) }
                OutlinedButton(onClick = { model.signIn(context) }, enabled = model.configured && !state.busy && !state.applePending,
                    modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp)) {
                    Image(painterResource(R.drawable.google_g), null, Modifier.size(20.dp)); Spacer(Modifier.width(12.dp)); Text("Sign in with Google")
                }
            }
            if (!model.appleConfigured) Text("Apple sign-in is not available in this build yet.", textAlign = TextAlign.Center)
            if (!model.configured) Text("Google sign-in is not available in this build yet.", textAlign = TextAlign.Center)
            if (state.applePending) {
                Text("Finish signing in with Apple in your browser, then return to Magpie.", textAlign = TextAlign.Center)
                TextButton(onClick = { model.reopenApple(context) }) { Text("Open Apple sign-in") }
                TextButton(onClick = model::cancelApple) { Text("Cancel Apple sign-in") }
            }
            if (state.busy) Row(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
                CircularProgressIndicator(Modifier.size(24.dp)); Text("Signing in…", Modifier.semantics { liveRegion = LiveRegionMode.Polite })
            }
            Spacer(Modifier.height(48.dp))
        }
    }
}
