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
    val url: String? = null, val sources: List<String> = emptyList(), val description: String? = null,
    val sourceDetails: List<FeedSource> = emptyList(), val forwarded: Boolean = false)
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
    suspend fun find(token: String, feedId: String?, query: String, limit: Int): List<RemoteEpisode> =
        (if (feedId != null) episodes(token, feedId, query) else if (query.isNotBlank()) search(token, query) else latest(token)).take(limit)
    suspend fun episode(token: String, episodeId: Int): RemoteEpisode = throw UnsupportedOperationException("Episode lookup is unavailable")
    suspend fun text(token: String, episodeId: Int, contentId: Int?): RemoteText
    suspend fun save(token: String, episodeId: Int? = null, url: String? = null): RemoteEpisode
    suspend fun remove(token: String, episodeId: Int)
    suspend fun played(token: String, episodeId: Int, played: Boolean)
    suspend fun clearLatest(token: String)
    suspend fun subscribe(token: String, url: String): LibraryFeed
    suspend fun position(token: String, episodeId: Int, seconds: Double, completed: Boolean)
}

/** Uses the existing Swift/backend wire contract. Authorization never follows redirects. */
class HttpLibraryApi(private val baseUrl: String, private val unauthorized: (String) -> Unit = {},
    private val connect: (java.net.URL) -> HttpURLConnection = { it.openConnection() as HttpURLConnection }) : LibraryApi, DiscoveryApi, SourceManagementApi, SavedArticleApi, NewsletterApi,
    com.henrydashwood.magpie.voice.VoiceApi by com.henrydashwood.magpie.voice.HttpVoiceApi(baseUrl, unauthorized),
    LibraryActionApi by com.henrydashwood.magpie.voice.HttpVoiceApi(baseUrl, unauthorized) {
    override suspend fun userId(token: String) = obj(token, "me").getString("id")
    override suspend fun feeds(token: String) = array(token, "feeds").objects().map(::decodeFeed)
    override suspend fun latest(token: String) = list(token, "episodes?limit=30")
    override suspend fun saved(token: String) = list(token, "saved")
    override suspend fun episodes(token: String, feedId: String, query: String): List<RemoteEpisode> {
        require(feedId.toIntOrNull() != null)
        return list(token, "feeds/$feedId/episodes?limit=50&q=${encode(query.take(200))}")
    }
    override suspend fun search(token: String, query: String) = list(token, "search/episodes?q=${encode(query.take(200))}")
    override suspend fun find(token: String, feedId: String?, query: String, limit: Int): List<RemoteEpisode> {
        require(limit in 1..100 && query.length <= 200)
        if (feedId != null) require(feedId.toIntOrNull()?.let { it > 0 } == true)
        val path = when {
            feedId != null -> "feeds/$feedId/episodes?limit=$limit&q=${encode(query)}"
            query.isNotBlank() -> "search/episodes?limit=$limit&q=${encode(query)}"
            else -> "episodes?limit=$limit"
        }
        return list(token, path)
    }
    override suspend fun episode(token: String, episodeId: Int): RemoteEpisode {
        require(episodeId > 0)
        return decodeEpisode(obj(token, "episodes/$episodeId"))
    }
    override suspend fun text(token: String, episodeId: Int, contentId: Int?): RemoteText {
        val json = obj(token, "episodes/$episodeId/text" + (contentId?.let { "?content_id=$it" } ?: ""))
        return RemoteText(json.getInt("episode_id"), json.optionalInt("content_id"), json.getString("text"),
            json.optionalString("html"), json.optionalInt("word_count"))
    }
    override suspend fun save(token: String, episodeId: Int?, url: String?) = decodeEpisode(obj(token, "saved", "POST",
        JSONObject().put("episode_id", episodeId).put("url", url)))
    override suspend fun capture(token: String, article: PendingArticle) = decodeEpisode(obj(token, if (article.replaceExisting) "saved/replace" else "saved", "POST", captureBody(article)))
    override suspend fun retrySaved(token: String, episodeId: Int) = decodeEpisode(obj(token, "saved/$episodeId/retry", "POST"))
    override suspend fun replaceSaved(token: String, episodeId: Int) = decodeEpisode(obj(token, "saved/replace", "POST", JSONObject().put("episode_id", episodeId)))
    override suspend fun remove(token: String, episodeId: Int) { request(token, "saved/$episodeId", "DELETE") }
    override suspend fun played(token: String, episodeId: Int, played: Boolean) {
        request(token, "episodes/$episodeId/state", "PUT", JSONObject().put("played", played))
    }
    override suspend fun clearLatest(token: String) { request(token, "episodes", "DELETE") }
    override suspend fun subscribe(token: String, url: String) = decodeFeed(obj(token, "feeds", "POST", JSONObject().put("url", url)))
    override suspend fun position(token: String, episodeId: Int, seconds: Double, completed: Boolean) {
        request(token, "episodes/$episodeId/position", "PUT", JSONObject().put("position_seconds", seconds).put("completed", completed))
    }
    override suspend fun directory(token: String, query: String) = array(token, "search/podcasts?q=${encode(query.take(200))}").objects().map(::decodeSource).distinctBy { it.url }
    override suspend fun discover(token: String, url: String) = obj(token, "feeds/discover", "POST",
        JSONObject().put("url", validateLink(url))).getJSONArray("candidates").objects().map(::decodeCandidate)
    override suspend fun preview(token: String, url: String) = decodePreview(obj(token, "feeds/preview", "POST",
        JSONObject().put("url", validateLink(url))))
    override suspend fun webSearch(token: String, query: String): SourceResult? {
        val result = request(token, "search/publications", "POST", JSONObject().put("query", query.take(200)))
        return if (result.trim() == "null") null else decodeSource(JSONObject(result))
    }
    override suspend fun aiConsent(token: String) = obj(token, "me").optBoolean("ai_data_sharing_consented", false)
    override suspend fun setAIConsent(token: String, granted: Boolean) = obj(token, "me/ai-data-sharing", "PUT",
        JSONObject().put("granted", granted)).optBoolean("ai_data_sharing_consented", false)
    override suspend fun feedSources(token: String, feedId: String): List<FeedSource> {
        require(feedId.toIntOrNull() != null)
        return array(token, "feeds/$feedId/sources").objects().map(::decodeFeedSource)
    }
    override suspend fun changeSources(token: String, feedId: String, sourceId: String?, change: SourceChange) {
        require(feedId.toIntOrNull() != null)
        val path = if (change == SourceChange.Unsubscribe) "feeds/$feedId" else {
            require(sourceId?.toIntOrNull() != null)
            "feeds/$feedId/sources/$sourceId"
        }
        request(token, path, if (change == SourceChange.Combine) "PUT" else "DELETE")
    }
    private suspend fun list(token: String, path: String) = array(token, path).objects().map(::decodeEpisode)
    override suspend fun newsletterAddress(token: String) = NewsletterAddress(obj(token, "newsletters/address").getString("address"))
    override suspend fun pendingNewsletters(token: String) = array(token, "newsletters/pending").objects().map { row ->
        PendingNewsletter(row.getInt("id"), row.getString("title"), row.getString("sender_address"),
            row.getInt("message_count"), row.optionalString("latest_title"), row.optionalString("latest_at"))
    }
    override suspend fun approveNewsletter(token: String, feedId: Int): LibraryFeed {
        require(feedId > 0)
        return decodeFeed(obj(token, "newsletters/$feedId/approve", "POST"))
    }
    override suspend fun blockNewsletter(token: String, feedId: Int) {
        require(feedId > 0)
        request(token, "newsletters/$feedId/block", "POST")
    }
    override suspend fun signUpForNewsletter(token: String, url: String): NewsletterSignup {
        val row = JSONObject(request(token, "newsletters/signups", "POST", JSONObject().put("url", validateLink(url)), 60_000))
        return NewsletterSignup(row.getString("status"), row.getString("spoken_response"), row.optionalString("address"),
            row.optionalString("publication"), row.optionalString("platform"), row.optionalString("reason"))
    }
    private suspend fun array(token: String, path: String) = JSONArray(request(token, path))
    private suspend fun obj(token: String, path: String, method: String = "GET", body: JSONObject? = null) = JSONObject(request(token, path, method, body))
    private suspend fun request(token: String, path: String, method: String = "GET", body: JSONObject? = null, timeout: Int = 30_000): String = withContext(Dispatchers.IO) {
        val base = URI(baseUrl)
        require(base.scheme == "https" && base.host != null && base.userInfo == null)
        val connection = connect(URI(baseUrl.trimEnd('/') + "/" + path).toURL())
        try {
            connection.requestMethod = method
            connection.instanceFollowRedirects = false
            connection.connectTimeout = 15_000
            connection.readTimeout = timeout
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
        fun captureBody(article: PendingArticle) = JSONObject().put("url", article.url).put("saved_at", article.savedAt)
            .put("title", article.title).put("html", article.html).put("content_format", article.contentFormat)
        private fun encode(value: String) = URLEncoder.encode(value, "UTF-8")
        fun decodeSource(json: JSONObject) = SourceResult(json.getString("title"), validateLink(json.getString("feed_url")),
            json.optionalString("publisher"), json.optionalInt("episode_count"))
        fun decodeCandidate(json: JSONObject) = SourceResult(json.getString("title"), validateLink(json.getString("feed_url")),
            count = json.optInt("item_count"), description = json.optionalString("description"), format = json.optionalString("format"),
            audioCount = json.optInt("audio_item_count"), recentTitle = json.optJSONArray("recent_item_titles")?.optString(0)?.takeIf { it.isNotBlank() },
            primary = json.optBoolean("is_primary"))
        fun decodePreview(json: JSONObject) = RemotePreview(decodeFeed(json.getJSONObject("feed")),
            json.getJSONArray("episodes").objects().map(::decodeEpisode), json.getBoolean("subscribed"))
        fun decodeFeedSource(json: JSONObject) = FeedSource(json.getInt("id").toString(), json.getString("title"),
            json.getString("url"), json.getString("source"), json.optBoolean("is_primary"), json.optBoolean("is_failing"))
        fun decodeFeed(json: JSONObject) = LibraryFeed(json.getInt("id").toString(), json.getString("title"),
            json.optInt("episode_count"), json.optBoolean("is_article_feed"), json.optionalString("url"),
            json.optJSONArray("sources")?.objects()?.map { it.getString("title") }.orEmpty(), json.optionalString("description"),
            json.optJSONArray("sources")?.objects()?.map(::decodeFeedSource).orEmpty(), json.optBoolean("forwarded"))
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
