package com.henrydashwood.magpie.auth

import android.content.Context
import android.content.ActivityNotFoundException
import androidx.browser.customtabs.CustomTabsIntent
import androidx.core.net.toUri
import org.json.JSONObject
import java.net.URI
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.Base64

data class AppleBrowserStart(val state: String, val authorizationUrl: String, val expiresIn: Int)
data class AppleBrowserResult(val status: String, val auth: AccountLogin? = null, val providers: Set<String>? = null)
data class ApplePending(val state: String, val verifier: String, val authorizationUrl: String,
    val expiresAt: Long, val sessionHash: String?)

interface ApplePendingStore {
    fun read(): ApplePending?
    fun write(pending: ApplePending)
    fun clear()
}
class MemoryApplePendingStore : ApplePendingStore {
    private var value: ApplePending? = null
    override fun read() = value
    override fun write(pending: ApplePending) { value = pending }
    override fun clear() { value = null }
}

class EncryptedApplePendingStore(private val encrypted: AccountTokenStore) : ApplePendingStore {
    override fun read(): ApplePending? = try {
        encrypted.read()?.let { raw ->
            val json = JSONObject(raw)
            ApplePending(json.getString("state"), json.getString("verifier"), json.getString("url"),
                json.getLong("expires"), if (json.isNull("session")) null else json.getString("session"))
        }
    } catch (_: Exception) { encrypted.clear(); null }
    override fun write(pending: ApplePending) {
        encrypted.write(JSONObject().put("state", pending.state).put("verifier", pending.verifier)
            .put("url", pending.authorizationUrl).put("expires", pending.expiresAt)
            .put("session", pending.sessionHash).toString())
    }
    override fun clear() { encrypted.clear() }
}

object AppleBrowserProof {
    fun verifier(): String = Base64.getUrlEncoder().withoutPadding().encodeToString(ByteArray(32).also { SecureRandom().nextBytes(it) })
    fun challenge(value: String): String = Base64.getUrlEncoder().withoutPadding()
        .encodeToString(MessageDigest.getInstance("SHA-256").digest(value.toByteArray(Charsets.UTF_8)))
    fun isAuthorizationUrl(value: String): Boolean = runCatching {
        val uri = URI(value)
        uri.scheme == "https" && uri.host == "appleid.apple.com" && uri.port == -1 &&
            uri.userInfo == null && uri.path == "/auth/authorize" && uri.fragment == null
    }.getOrDefault(false)
}

fun openAppleBrowser(context: Context, url: String) {
    if (!AppleBrowserProof.isAuthorizationUrl(url)) throw AccountFailure(0, "Apple sign-in could not be opened.")
    try { CustomTabsIntent.Builder().setShowTitle(true).build().launchUrl(context, url.toUri()) }
    catch (_: ActivityNotFoundException) { throw AccountFailure(0, "Install or enable a web browser to sign in with Apple.") }
}
