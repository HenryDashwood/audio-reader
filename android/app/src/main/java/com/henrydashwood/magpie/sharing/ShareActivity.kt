package com.henrydashwood.magpie.sharing

import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.lifecycle.ViewModelProvider
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.*
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.henrydashwood.magpie.MainActivity
import com.henrydashwood.magpie.ui.MagpieTheme

class ShareActivity : ComponentActivity() {
    private val model by lazy { ViewModelProvider(this)[ShareModel::class.java] }
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        model.receive(intent, savedInstanceState?.getBoolean("saved") == true, capture = capturing(intent))
        setContent { MagpieTheme { ShareScreen(model, ::finish, ::openMagpie) } }
    }
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent); setIntent(intent); model.receive(intent, fresh = true, capture = capturing(intent))
    }
    override fun onSaveInstanceState(outState: Bundle) {
        // Never put page HTML in the activity bundle. After process death, an unconfirmed
        // browser preview returns to the original share for fresh review.
        outState.putBoolean("saved", model.state.value.saved)
        super.onSaveInstanceState(outState)
    }
    private fun capturing(intent: Intent) = intent.component?.className == CAPTURE_PAGE
    companion object { const val CAPTURE_PAGE = "com.henrydashwood.magpie.sharing.CapturePage" }
    private fun openMagpie() {
        startActivity(Intent(this, MainActivity::class.java).putExtra("open_saved", true)
            .putExtra("open_signin", !model.library.value.live)
            .addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP))
        if (model.state.value.saved) finish()
    }
}

@Composable
fun ShareScreen(model: ShareModel, close: () -> Unit, openMagpie: () -> Unit) {
    val state by model.state.collectAsStateWithLifecycle()
    val library by model.library.collectAsStateWithLifecycle()
    if (state.browser && state.article != null) {
        CaptureBrowser(state.article!!.url, model::closeBrowser, model::captured)
        return
    }
    BackHandler(enabled = state.busy) { /* Keep the durable-write acknowledgement visible. */ }
    val reading = state.article?.url?.takeIf { state.preparing }
    if (reading != null) key(reading) { HiddenPageCapture(reading, model::prepared) }
    Scaffold { padding ->
        Column(Modifier.fillMaxSize().padding(padding).verticalScroll(rememberScrollState()).padding(24.dp),
            verticalArrangement = Arrangement.spacedBy(20.dp)) {
            Text(if (state.saved) "Saved to Magpie" else "Save to Magpie", style = MaterialTheme.typography.headlineMedium,
                modifier = Modifier.semantics { heading(); liveRegion = LiveRegionMode.Polite })
            if (state.busy || state.saveRequested) LinearProgressIndicator(Modifier.fillMaxWidth())
            if (state.preparing) Text(if (state.saveRequested) "Reading the page before saving…" else "Reading the page…",
                modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite })
            state.error?.let { Text(it, color = MaterialTheme.colorScheme.error, modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite }) }
            state.article?.let { article ->
                article.title?.let { Text(it, style = MaterialTheme.typography.titleLarge) }
                Text(article.url)
                article.preview?.let { Text(it, Modifier.semantics { contentDescription = "Article begins: $it" }) }
                if (!state.saved) {
                    // As on iOS: one Save, which keeps the page read above. If it can't be read,
                    // the link is saved and Saved offers "Capture page" when the server fetch fails.
                    Text("Ready to read or listen to later.")
                    Text("Already saved? This updates your copy. If the text changes, listening starts from the beginning.")
                }
            }
            when {
                state.saved -> {
                    Text("Saved on this device. Open Magpie to prepare it for reading and listening.")
                    Button(onClick = openMagpie) { Text("Open Magpie") }
                    TextButton(onClick = close) { Text("Done") }
                }
                state.accountChanged -> {
                    Button(onClick = model::reviewAccount) { Text("Review again") }
                    TextButton(onClick = close) { Text("Cancel") }
                }
                else -> {
                    if (!library.live || library.owner == null) {
                        Text(if (!library.live) "Sign in to Magpie before saving. Return here afterward to review and save this article."
                            else "Connect to load your Magpie account before saving. Open Magpie to retry.")
                        Button(onClick = openMagpie, enabled = !state.busy) { Text("Open Magpie") }
                    } else if (state.article != null) {
                        Button(onClick = model::save, enabled = !state.busy && !state.saveRequested) { Text("Save article") }
                    }
                    TextButton(onClick = close, enabled = !state.busy) { Text("Cancel") }
                }
            }
        }
    }
}
