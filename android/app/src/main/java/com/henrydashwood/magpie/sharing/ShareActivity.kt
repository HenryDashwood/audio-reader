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
        model.receive(intent, savedInstanceState?.getBoolean("saved") == true)
        setContent { MagpieTheme { ShareScreen(model, ::finish, ::openMagpie) } }
    }
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent); setIntent(intent); model.receive(intent, fresh = true)
    }
    override fun onSaveInstanceState(outState: Bundle) {
        // Never put page HTML in the activity bundle. After process death, an unconfirmed
        // browser preview returns to the original share for fresh review.
        outState.putBoolean("saved", model.state.value.saved)
        super.onSaveInstanceState(outState)
    }
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
    Scaffold { padding ->
        Column(Modifier.fillMaxSize().padding(padding).verticalScroll(rememberScrollState()).padding(24.dp),
            verticalArrangement = Arrangement.spacedBy(20.dp)) {
            Text(if (state.saved) "Saved to Magpie" else "Save to Magpie", style = MaterialTheme.typography.headlineMedium,
                modifier = Modifier.semantics { heading(); liveRegion = LiveRegionMode.Polite })
            if (state.busy) LinearProgressIndicator(Modifier.fillMaxWidth())
            state.error?.let { Text(it, color = MaterialTheme.colorScheme.error, modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite }) }
            state.article?.let { article ->
                article.title?.let { Text(it, style = MaterialTheme.typography.titleLarge) }
                Text(article.url)
                article.preview?.let { Text(it, Modifier.semantics { contentDescription = "Article begins: $it" }) }
                if (!state.saved) {
                    Text(if (article.html != null) "The shared page content will be saved to your current Magpie account."
                        else "Save this link, or open the page in Magpie to capture the article you can see.")
                    Text("Already saved? This updates your copy. If the text changes, listening starts from the beginning. If preparation fails, your current copy is kept.")
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
                        Button(onClick = model::save, enabled = !state.busy) { Text("Save article") }
                    }
                    if (state.article?.url?.startsWith("https://", true) == true) {
                        OutlinedButton(onClick = model::openBrowser, enabled = !state.busy) { Text("Capture page") }
                        Text("The page opens inside Magpie. You may need to sign in to the website here.", style = MaterialTheme.typography.bodySmall)
                    }
                    TextButton(onClick = close, enabled = !state.busy) { Text("Cancel") }
                }
            }
        }
    }
}
