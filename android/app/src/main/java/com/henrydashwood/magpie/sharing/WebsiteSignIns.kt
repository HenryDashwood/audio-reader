package com.henrydashwood.magpie.sharing

import android.content.Context
import android.webkit.CookieManager
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.rounded.ChevronRight
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.*
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import java.net.URI

/** Websites the user opened to sign in. Only the addresses are kept here; the browser keeps the cookies. */
class WebsiteSignInStore(context: Context) {
    private val preferences = context.applicationContext.getSharedPreferences("magpie_website_sign_ins", Context.MODE_PRIVATE)
    fun sites(): List<String> = preferences.getStringSet(KEY, emptySet()).orEmpty().sorted()
    fun remember(url: String) { preferences.edit().putStringSet(KEY, sites().toSet() + websiteHome(url)).apply() }
    /** Signs out of every website in Magpie's browser, including any not listed. */
    fun signOutAll(done: () -> Unit) {
        preferences.edit().remove(KEY).apply()
        CookieManager.getInstance().removeAllCookies { CookieManager.getInstance().flush(); done() }
        android.webkit.WebStorage.getInstance().deleteAllData()
    }
    private companion object { const val KEY = "sites" }
}

/** "nytimes.com" or a pasted article link becomes a secure address, or null when it can't. */
fun websiteAddress(raw: String): String? {
    val value = raw.trim().takeIf { it.isNotEmpty() && !it.contains(' ') } ?: return null
    val url = if (value.contains("://")) value else "https://$value"
    return url.takeIf(::captureWebUrl)
}

fun websiteHome(url: String): String = URI(url).let { "https://${it.host}" }

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun WebsiteSignInsScreen(close: () -> Unit) {
    val context = LocalContext.current
    val store = remember { WebsiteSignInStore(context) }
    var sites by remember { mutableStateOf(store.sites()) }
    var browsing by rememberSaveable { mutableStateOf<String?>(null) }
    var entry by rememberSaveable { mutableStateOf("") }
    var error by rememberSaveable { mutableStateOf<String?>(null) }
    var confirmingSignOut by remember { mutableStateOf(false) }
    var notice by rememberSaveable { mutableStateOf<String?>(null) }
    browsing?.let { url ->
        CaptureBrowser(url, close = { browsing = null; sites = store.sites() }, signIn = true)
        return
    }
    fun open(raw: String) {
        val url = websiteAddress(raw)
        if (url == null) { error = "Enter a website address, such as nytimes.com."; return }
        error = null; notice = null; entry = ""; store.remember(url); browsing = url
    }
    BackHandler(onBack = close)
    Scaffold(topBar = {
        TopAppBar(title = { Text("Website Sign-ins") }, navigationIcon = {
            IconButton(onClick = close) { Icon(Icons.AutoMirrored.Rounded.ArrowBack, "Back") }
        })
    }) { padding ->
        LazyColumn(Modifier.fillMaxSize().padding(padding).testTag("website-sign-ins"), contentPadding = PaddingValues(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp)) {
            item {
                Text("When you share an article from Chrome, Magpie reads the page itself. Chrome’s sign-ins aren’t shared with Magpie, so sign in here once to websites you subscribe to.")
            }
            item {
                OutlinedTextField(entry, { entry = it; error = null }, Modifier.fillMaxWidth(), label = { Text("Website address") },
                    singleLine = true, isError = error != null,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri, imeAction = ImeAction.Go),
                    keyboardActions = KeyboardActions(onGo = { open(entry) }))
                error?.let { Text(it, color = MaterialTheme.colorScheme.error, modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite }) }
                Button(onClick = { open(entry) }, Modifier.padding(top = 8.dp)) { Text("Open website") }
            }
            if (sites.isNotEmpty()) {
                item { Text("Websites you’ve opened", style = MaterialTheme.typography.titleMedium, modifier = Modifier.semantics { heading() }) }
                items(sites, key = { it }) { site ->
                    ListItem(headlineContent = { Text(URI(site).host.removePrefix("www.")) },
                        trailingContent = { Icon(Icons.Rounded.ChevronRight, null) },
                        modifier = Modifier.clickable(onClickLabel = "Open website") { notice = null; browsing = site })
                }
            }
            item {
                TextButton(onClick = { confirmingSignOut = true }) { Text("Sign out of all websites", color = MaterialTheme.colorScheme.error) }
                notice?.let { Text(it, modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite }) }
            }
        }
    }
    if (confirmingSignOut) AlertDialog(onDismissRequest = { confirmingSignOut = false },
        title = { Text("Sign out of all websites?") },
        text = { Text("Magpie forgets website sign-ins. Your Magpie account and saved articles are not affected.") },
        confirmButton = { TextButton(onClick = {
            confirmingSignOut = false
            store.signOutAll { sites = store.sites(); notice = "Signed out of all websites." }
        }) { Text("Sign Out", color = MaterialTheme.colorScheme.error) } },
        dismissButton = { TextButton(onClick = { confirmingSignOut = false }) { Text("Cancel") } })
}
