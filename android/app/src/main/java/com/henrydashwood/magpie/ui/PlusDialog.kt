package com.henrydashwood.magpie.ui

import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import android.content.Intent
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.*
import androidx.compose.ui.unit.dp
import androidx.core.net.toUri
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.henrydashwood.magpie.MagpieApplication
import com.henrydashwood.magpie.billing.PlusBilling
import com.henrydashwood.magpie.billing.PlusStatus
import com.revenuecat.purchases.Package
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch
import java.time.OffsetDateTime
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle

private fun Context.activity(): Activity? = when (this) {
    is Activity -> this
    is ContextWrapper -> baseContext.activity()
    else -> null
}

@Composable
fun PlusDialog(onClose: () -> Unit) {
    val context = LocalContext.current
    val app = context.applicationContext as MagpieApplication
    val token by app.accounts.accessToken.collectAsStateWithLifecycle()
    val scope = rememberCoroutineScope()
    var status by remember(token) { mutableStateOf<PlusStatus?>(null) }
    var monthly by remember(token) { mutableStateOf<Package?>(null) }
    var busy by remember(token) { mutableStateOf(false) }
    var error by remember(token) { mutableStateOf<String?>(null) }
    var message by remember(token) { mutableStateOf<String?>(null) }
    suspend fun load(restore: Boolean = false, purchase: Package? = null, refresh: Boolean = false) {
        if (busy) return
        busy = true; error = null; message = null
        val credential = token
        try {
            checkNotNull(credential) { "Sign in to Magpie to manage your subscription." }
            val result = PlusBilling.perform(context, credential, { app.accounts.accessToken.value == credential },
                context.activity(), purchase, restore, refresh)
            if (app.accounts.accessToken.value != credential) return
            status = result.first; monthly = result.second
            if (restore) message = if (result.first.active) "Purchases restored." else "No active Magpie Plus subscription was found for this store account."
            if (purchase != null && result.first.active) message = "Magpie Plus is ready. You can import PDFs now."
        } catch (cancelled: CancellationException) { throw cancelled }
        catch (failure: Exception) { if (token == credential) error = failure.message ?: "The subscription could not be checked. Please try again." }
        finally { if (token == credential) busy = false }
    }
    fun link(url: String) {
        try { context.startActivity(Intent(Intent.ACTION_VIEW, url.toUri())) }
        catch (_: Exception) { error = "No app is available to open this link." }
    }
    LaunchedEffect(token) { load() }
    AlertDialog(onDismissRequest = { if (!busy) onClose() },
        title = { Text("Magpie Plus", Modifier.semantics { heading() }) },
        text = { Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text("Turn PDFs into readable articles, including equations and images.")
            Text("500 pages per billing month. Unused pages do not roll over. PDFs you have already imported remain readable after cancellation.")
            status?.let { state ->
                when {
                    state.unlimited -> Text("Your account has unlimited PDF imports.")
                    state.active -> {
                        Text("${state.remainingPages ?: 0} of ${state.monthlyPages} pages remaining")
                        state.periodEnd?.let { value -> runCatching { OffsetDateTime.parse(value).format(DateTimeFormatter.ofLocalizedDate(FormatStyle.MEDIUM)) }.getOrNull()?.let { Text("Renews $it") } }
                        TextButton(onClick = { link(if (state.store == "app_store") "https://apps.apple.com/account/subscriptions" else "https://play.google.com/store/account/subscriptions") }) { Text("Manage subscription") }
                    }
                    state.available && monthly != null -> {
                        Button(onClick = { scope.launch { load(purchase = monthly) } }, enabled = !busy) { Text("Subscribe · ${monthly?.product?.price?.formatted} / month") }
                        Text("Payment is charged to your Google Play account. Renews automatically each month unless cancelled in Google Play before renewal.")
                    }
                    else -> Text(if (state.available) "The monthly subscription is temporarily unavailable. Please try again." else "Magpie Plus is not available to purchase yet.")
                }
                if (state.available && !state.unlimited) TextButton(onClick = { scope.launch { load(restore = true) } }, enabled = !busy) { Text("Restore purchases") }
            }
            if (busy) LinearProgressIndicator(Modifier.fillMaxWidth())
            error?.let { Text(it, color = MaterialTheme.colorScheme.error, modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite }) }
            message?.let { Text(it, Modifier.semantics { liveRegion = LiveRegionMode.Polite }) }
            TextButton(onClick = { scope.launch { load(refresh = true) } }, enabled = !busy) { Text("Refresh") }
            TextButton(onClick = { link("https://audio-reader-production.up.railway.app/privacy") }) { Text("Privacy Policy") }
            TextButton(onClick = { link("https://audio-reader-production.up.railway.app/terms") }) { Text("Terms of Use") }
        } },
        confirmButton = { TextButton(onClick = onClose, enabled = !busy) { Text("Done") } })
}
