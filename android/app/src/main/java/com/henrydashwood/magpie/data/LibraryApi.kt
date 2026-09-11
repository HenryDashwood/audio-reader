package com.henrydashwood.magpie.data

import com.henrydashwood.magpie.auth.AccountFailure
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URI
import java.net.URLEncoder
import java.io.ByteArrayOutputStream

data class LibraryFeed(val id: String, val title: String, val count: Int, val articles: Boolean,
    val url: String? = null, val sources: List<String> = emptyList())
data class RemoteEpisode(val id: Int, val title: String, val description: String = "", val source: String = "Saved articles",
    val feedUrl: String? = null, val audioUrl: String? = null, val link: String? = null,
    val durationSeconds: Int? = null, val wordCount: Int? = null, val positionSeconds: Double = 0.0,
    val completed: Boolean = false, val dismissed: Boolean = false, val contentId: Int? = null,
    val captureError: String? = null)
data class RemoteText(val episodeId: Int, val contentId: Int?, val text: String, val html: String?, val wordCount: Int?)

interface LibraryApi {
    suspend fun userId(token: String): String
    suspend fun feeds(token: String): List<LibraryFeed>
    suspend fun latest(token: String): List<RemoteEpisode>
    suspend fun saved(token: String): List<RemoteEpisode>
    suspend fun episodes(token: String, feedId: String, query: String): List<RemoteEpisode>
    suspend fun search(token: String, query: String): List<RemoteEpisode>
    suspend fun text(token: String, episodeId: Int, contentId: Int?): RemoteText
    suspend fun save(token: String, episodeId: Int? = null, url: String? = null): RemoteEpisode
    suspend fun remove(token: String, episodeId: Int)
    suspend fun played(token: String, episodeId: Int, played: Boolean)
    suspend fun clearLatest(token: String)
    suspend fun subscribe(token: String, url: String): LibraryFeed
    suspend fun position(token: String, episodeId: Int, seconds: Double, completed: Boolean)
}

/** Uses the existing Swift/backend wire contract. Authorization never follows redirects. */
class HttpLibraryApi(private val baseUrl: String, private val unauthorized: (String) -> Unit = {}) : LibraryApi {
    override suspend fun userId(token: String) = obj(token, "me").getString("id")
    override suspend fun feeds(token: String) = array(token, "feeds").objects().map(::decodeFeed)
    override suspend fun latest(token: String) = list(token, "episodes?limit=30")
    override suspend fun saved(token: String) = list(token, "saved")
    override suspend fun episodes(token: String, feedId: String, query: String): List<RemoteEpisode> {
        require(feedId.toIntOrNull() != null)
        return list(token, "feeds/$feedId/episodes?limit=50&q=${encode(query.take(200))}")
    }
    override suspend fun search(token: String, query: String) = list(token, "search/episodes?q=${encode(query.take(200))}")
    override suspend fun text(token: String, episodeId: Int, contentId: Int?): RemoteText {
        val json = obj(token, "episodes/$episodeId/text" + (contentId?.let { "?content_id=$it" } ?: ""))
        return RemoteText(json.getInt("episode_id"), json.optionalInt("content_id"), json.getString("text"),
            json.optionalString("html"), json.optionalInt("word_count"))
    }
    override suspend fun save(token: String, episodeId: Int?, url: String?) = decodeEpisode(obj(token, "saved", "POST",
        JSONObject().put("episode_id", episodeId).put("url", url)))
    override suspend fun remove(token: String, episodeId: Int) { request(token, "saved/$episodeId", "DELETE") }
    override suspend fun played(token: String, episodeId: Int, played: Boolean) {
        request(token, "episodes/$episodeId/state", "PUT", JSONObject().put("played", played))
    }
    override suspend fun clearLatest(token: String) { request(token, "episodes", "DELETE") }
    override suspend fun subscribe(token: String, url: String) = decodeFeed(obj(token, "feeds", "POST", JSONObject().put("url", url)))
    override suspend fun position(token: String, episodeId: Int, seconds: Double, completed: Boolean) {
        request(token, "episodes/$episodeId/position", "PUT", JSONObject().put("position_seconds", seconds).put("completed", completed))
    }
    private suspend fun list(token: String, path: String) = array(token, path).objects().map(::decodeEpisode)
    private suspend fun array(token: String, path: String) = JSONArray(request(token, path))
    private suspend fun obj(token: String, path: String, method: String = "GET", body: JSONObject? = null) = JSONObject(request(token, path, method, body))
    private suspend fun request(token: String, path: String, method: String = "GET", body: JSONObject? = null): String = withContext(Dispatchers.IO) {
        val base = URI(baseUrl)
        require(base.scheme == "https" && base.host != null && base.userInfo == null)
        val connection = URI(baseUrl.trimEnd('/') + "/" + path).toURL().openConnection() as HttpURLConnection
        try {
            connection.requestMethod = method
            connection.instanceFollowRedirects = false
            connection.connectTimeout = 15_000
            connection.readTimeout = 30_000
            connection.setRequestProperty("Accept", "application/json")
            connection.setRequestProperty("Authorization", "Bearer $token")
            if (body != null) {
                connection.doOutput = true
                connection.setRequestProperty("Content-Type", "application/json")
                connection.outputStream.use { it.write(body.toString().toByteArray(Charsets.UTF_8)) }
            }
            val status = connection.responseCode
            val input = if (status in 200..299) connection.inputStream else connection.errorStream
            val bytes = input?.use {
                val output = ByteArrayOutputStream()
                val buffer = ByteArray(8192)
                while (output.size() <= 8 * 1024 * 1024) {
                    val count = it.read(buffer)
                    if (count < 0) break
                    output.write(buffer, 0, count)
                }
                output.toByteArray()
            } ?: byteArrayOf()
            if (bytes.size > 8 * 1024 * 1024) throw AccountFailure(status, "This library response is too large to open.")
            val result = bytes.toString(Charsets.UTF_8)
            if (status !in 200..299) {
                if (status == 401) withContext(Dispatchers.Main) { unauthorized(token) }
                val message = runCatching { JSONObject(result).optJSONObject("detail")?.optionalString("spoken_response") }.getOrNull()
                throw AccountFailure(status, message ?: if (status == 401) "Please sign in again to load your library." else "Your library could not be updated. Please try again.")
            }
            result
        } finally { connection.disconnect() }
    }
    companion object {
        private fun encode(value: String) = URLEncoder.encode(value, "UTF-8")
        fun decodeFeed(json: JSONObject) = LibraryFeed(json.getInt("id").toString(), json.getString("title"),
            json.optInt("episode_count"), json.optBoolean("is_article_feed"), json.optionalString("url"),
            json.optJSONArray("sources")?.objects()?.map { it.getString("title") }.orEmpty())
        fun decodeEpisode(json: JSONObject) = RemoteEpisode(json.getInt("id"), json.getString("title"),
            json.optionalString("description") ?: "", json.optionalString("feed_title") ?: "Saved articles",
            json.optionalString("feed_url"), https(json.optionalString("audio_url")), https(json.optionalString("link")),
            json.optionalInt("duration_seconds"), json.optionalInt("word_count"),
            json.optDouble("position_seconds", 0.0).takeIf { it.isFinite() && it >= 0 } ?: 0.0,
            json.optBoolean("completed"), json.optBoolean("dismissed"), json.optionalInt("content_id"), json.optionalString("capture_error"))
        private fun https(value: String?): String? = value?.takeIf { runCatching {
            val uri = URI(it); uri.scheme == "https" && uri.host != null && uri.userInfo == null
        }.getOrDefault(false) }
    }
}
private fun JSONObject.optionalString(key: String) = if (isNull(key)) null else getString(key)
private fun JSONObject.optionalInt(key: String) = if (isNull(key)) null else getInt(key)
private fun JSONArray.objects() = (0 until length()).map { getJSONObject(it) }
