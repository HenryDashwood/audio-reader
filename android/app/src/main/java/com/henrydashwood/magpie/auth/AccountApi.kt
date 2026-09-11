package com.henrydashwood.magpie.auth

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URI
import java.io.ByteArrayOutputStream
import com.henrydashwood.magpie.BuildConfig

// Provider credentials are exchanged for a Magpie session; email is never an account key.
data class AccountUser(val id: String, val displayName: String?)
data class AccountLogin(val token: String, val user: AccountUser)
class AccountFailure(val status: Int, override val message: String) : Exception(message)

interface AccountApi {
    suspend fun startApple(challenge: String, session: String?): AppleBrowserStart = throw AccountFailure(503, "Apple sign-in is unavailable.")
    suspend fun completeApple(state: String, verifier: String, session: String?): AppleBrowserResult = throw AccountFailure(503, "Apple sign-in is unavailable.")
    suspend fun cancelApple(state: String, verifier: String) {}
    suspend fun loginGoogle(identityToken: String): AccountLogin
    suspend fun me(token: String): AccountUser
    suspend fun providers(token: String): Set<String>
    suspend fun linkGoogle(token: String, identityToken: String): Set<String>
    suspend fun logout(token: String)
    suspend fun delete(token: String)
}

class HttpAccountApi(private val baseUrl: String) : AccountApi {
    override suspend fun startApple(challenge: String, session: String?): AppleBrowserStart {
        val json = request("auth/apple/browser/start", "POST", session, JSONObject()
            .put("challenge", challenge).put("purpose", if (session == null) "login" else "link")
            .put("return_scheme", BuildConfig.APPLICATION_ID + ".auth"))
        return AppleBrowserStart(json.getString("state"), json.getString("authorization_url"), json.getInt("expires_in"))
    }
    override suspend fun completeApple(state: String, verifier: String, session: String?): AppleBrowserResult {
        val json = request("auth/apple/browser/complete", "POST", session, proof(state, verifier))
        val auth = json.optJSONObject("auth")?.let { AccountLogin(it.getString("token"), user(it.getJSONObject("user"))) }
        val linked = if (json.isNull("providers")) null else providers(json)
        return AppleBrowserResult(json.getString("status"), auth, linked)
    }
    override suspend fun cancelApple(state: String, verifier: String) {
        request("auth/apple/browser/cancel", "POST", body = proof(state, verifier))
    }
    private fun proof(state: String, verifier: String) = JSONObject().put("state", state).put("verifier", verifier)
    override suspend fun loginGoogle(identityToken: String): AccountLogin {
        val result = request("auth/google", "POST", body = JSONObject().put("identity_token", identityToken))
        val token = result.getString("token")
        require(token.isNotBlank())
        return AccountLogin(token, user(result.getJSONObject("user")))
    }
    override suspend fun me(token: String) = user(request("me", token = token))
    override suspend fun providers(token: String) = providers(request("me/identities", token = token))
    override suspend fun linkGoogle(token: String, identityToken: String) = providers(
        request("me/identities/google", "POST", token, JSONObject().put("identity_token", identityToken)))
    override suspend fun logout(token: String) { request("auth/logout", "POST", token) }
    override suspend fun delete(token: String) { request("me", "DELETE", token) }

    private fun user(json: JSONObject) = AccountUser(json.getString("id"),
        if (json.isNull("display_name")) null else json.getString("display_name"))
    private fun providers(json: JSONObject): Set<String> {
        val values = json.getJSONArray("providers")
        return (0 until values.length()).map { values.getString(it) }.toSet()
    }

    private suspend fun request(path: String, method: String = "GET", token: String? = null,
        body: JSONObject? = null): JSONObject = withContext(Dispatchers.IO) {
        val base = URI(baseUrl)
        require(base.scheme == "https" && base.host != null && base.userInfo == null)
        val connection = URI(baseUrl.trimEnd('/') + "/" + path).toURL().openConnection() as HttpURLConnection
        try {
            connection.requestMethod = method
            connection.instanceFollowRedirects = false
            connection.connectTimeout = 15_000
            connection.readTimeout = 15_000
            connection.setRequestProperty("Accept", "application/json")
            if (token != null) connection.setRequestProperty("Authorization", "Bearer $token")
            if (body != null) {
                connection.doOutput = true
                connection.setRequestProperty("Content-Type", "application/json")
                connection.outputStream.use { it.write(body.toString().toByteArray(Charsets.UTF_8)) }
            }
            val status = connection.responseCode
            val stream = if (status in 200..299) connection.inputStream else connection.errorStream
            val bytes = stream?.use { input ->
                val output = ByteArrayOutputStream()
                val buffer = ByteArray(8192)
                while (output.size() <= 1_048_576) {
                    val count = input.read(buffer)
                    if (count < 0) break
                    output.write(buffer, 0, count)
                }
                output.toByteArray()
            } ?: byteArrayOf()
            if (bytes.size > 1_048_576) throw AccountFailure(status, "The server response could not be read. Please try again.")
            val json = if (bytes.isEmpty()) JSONObject() else runCatching { JSONObject(bytes.toString(Charsets.UTF_8)) }.getOrNull()
            if (status !in 200..299) {
                val spoken = json?.optJSONObject("detail")?.optString("spoken_response")?.takeIf { it.isNotBlank() }
                throw AccountFailure(status, spoken ?: if (status == 401) "Please sign in again." else "The account request did not work. Please try again.")
            }
            json ?: throw AccountFailure(status, "The server response could not be read. Please try again.")
        } finally { connection.disconnect() }
    }
}
