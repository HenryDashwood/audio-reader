package com.henrydashwood.magpie.billing

import android.app.Activity
import android.content.Context
import com.henrydashwood.magpie.BuildConfig
import com.revenuecat.purchases.*
import com.revenuecat.purchases.Package
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.net.HttpURLConnection
import java.net.URI

/** Only this server response grants PDF conversion access; SDK entitlements never grant quota locally. */
data class PlusStatus(val available: Boolean, val active: Boolean, val unlimited: Boolean,
    val customerId: String, val sdkKey: String, val offeringId: String, val monthlyPages: Int,
    val usedPages: Int, val remainingPages: Int?, val periodEnd: String?, val store: String?) {
    companion object {
        fun decode(json: JSONObject) = PlusStatus(json.getBoolean("available"), json.getBoolean("active"),
            json.getBoolean("unlimited"), json.getString("customer_id"), json.getString("google_sdk_key"),
            json.getString("offering_id"), json.getInt("monthly_pages"), json.getInt("used_pages"),
            if (json.isNull("remaining_pages")) null else json.getInt("remaining_pages"),
            if (json.isNull("period_end")) null else json.getString("period_end"),
            if (json.isNull("store")) null else json.getString("store"))
    }
}

class PlusClient(private val baseUrl: String, private val token: String,
    private val connect: (java.net.URL) -> HttpURLConnection = { it.openConnection() as HttpURLConnection }) {
    suspend fun status(sync: Boolean = false): PlusStatus = withContext(Dispatchers.IO) {
        val uri = URI(baseUrl.trimEnd('/') + if (sync) "/billing/sync" else "/billing/status")
        require(uri.scheme == "https" && uri.host != null && uri.userInfo == null)
        val connection = connect(uri.toURL())
        try {
            connection.requestMethod = if (sync) "POST" else "GET"
            connection.instanceFollowRedirects = false
            connection.useCaches = false
            connection.connectTimeout = 15_000
            connection.readTimeout = 30_000
            connection.setRequestProperty("Authorization", "Bearer $token")
            val code = connection.responseCode
            val stream = if (code in 200..299) connection.inputStream else connection.errorStream
            val raw = stream?.use { input ->
                val output = ByteArrayOutputStream()
                val buffer = ByteArray(4096)
                while (output.size() <= 65_536) {
                    val count = input.read(buffer)
                    if (count < 0) break
                    output.write(buffer, 0, count)
                }
                output.toByteArray()
            } ?: byteArrayOf()
            check(raw.size <= 65_536) { "Subscription response was too large." }
            val json = JSONObject(raw.toString(Charsets.UTF_8))
            check(code in 200..299) { json.opt("detail") as? String ?: "Subscription status is unavailable. Please try again." }
            PlusStatus.decode(json)
        } finally { connection.disconnect() }
    }
}

/** One serialized SDK session: identity changes cannot race an in-flight purchase or restore. */
object PlusBilling {
    private val mutex = Mutex()
    private var configuredKey: String? = null

    suspend fun perform(context: Context, token: String, current: () -> Boolean,
        activity: Activity? = null, purchase: Package? = null, restore: Boolean = false, refresh: Boolean = false, configureOnly: Boolean = false): Pair<PlusStatus, Package?> = mutex.withLock {
        fun checkAccount() = check(current()) { "Your account changed. Reopen Magpie Plus." }
        checkAccount()
        val client = PlusClient(BuildConfig.ACCOUNT_API_URL, token)
        var status = client.status(sync = refresh)
        checkAccount()
        if (!status.available || status.unlimited) return@withLock status to null
        check(status.sdkKey.startsWith("goog_")) { "Subscriptions are not available in this build yet." }
        if (configuredKey == null) {
            Purchases.configure(PurchasesConfiguration.Builder(context.applicationContext, status.sdkKey)
                .appUserID(status.customerId).build())
            configuredKey = status.sdkKey
        } else check(configuredKey == status.sdkKey) { "Restart Magpie after changing servers." }
        if (Purchases.sharedInstance.appUserID != status.customerId) {
            withContext(NonCancellable) { Purchases.sharedInstance.awaitLogIn(status.customerId) }
            checkAccount()
        }
        if (configureOnly) return@withLock status to null
        if (restore) {
            withContext(NonCancellable) { Purchases.sharedInstance.awaitRestore() }
            checkAccount()
            status = client.status(sync = true)
        } else if (purchase != null) {
            try {
                // Keep the identity mutex until the store finishes, even if this screen closes.
                withContext(NonCancellable) {
                    Purchases.sharedInstance.awaitPurchase(PurchaseParams.Builder(checkNotNull(activity), purchase).build())
                }
                checkAccount()
                status = client.status(sync = true)
            } catch (failure: PurchasesTransactionException) {
                if (!failure.userCancelled) throw failure
            }
        }
        checkAccount()
        if (status.active) return@withLock status to null
        val offerings = try { Purchases.sharedInstance.awaitOfferings() }
        catch (cancelled: kotlinx.coroutines.CancellationException) { throw cancelled }
        catch (_: Exception) { null }
        checkAccount()
        status to offerings?.all?.get(status.offeringId)?.monthly
    }
}
