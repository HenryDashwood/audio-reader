package com.henrydashwood.magpie.voice

import android.content.Context
import android.util.AtomicFile
import com.henrydashwood.magpie.data.RemoteEpisode
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.FileNotFoundException

/** Unfinished request text and receipts only, private and excluded from backup. */
class FileConversationStore(private val directory: File) : ConversationStore {
    constructor(context: Context) : this(File(context.noBackupFilesDir, "voice-requests"))
    private fun file(owner: String): AtomicFile {
        require(owner.matches(Regex("[a-f0-9]{64}")))
        return AtomicFile(File(directory, "$owner.json"))
    }
    override suspend fun read(owner: String): List<RecoverableVoiceRequest> = withContext(Dispatchers.IO) { synchronized(lock) {
        val raw = try { file(owner).openRead().use { stream ->
            require(stream.channel.size() <= 8 * 1024 * 1024)
            stream.bufferedReader().readText()
        } }
            catch (_: FileNotFoundException) { return@synchronized emptyList() }
        // Never silently delete an unreadable original request and invent a replacement ID.
        val root = JSONObject(raw)
        require(root.getInt("schema") in 1..2 && root.getString("owner") == owner)
        val entries = root.getJSONArray("requests")
        require(entries.length() <= 100)
        (0 until entries.length()).map { index ->
            val row = entries.getJSONObject(index); val request = row.getJSONObject("request")
            RecoverableVoiceRequest(VoiceRequest(request.getString("transcript"), request.getString("request_id"),
                request.optionalInt("viewed_episode_id"), request.optionalInt("now_playing_episode_id"),
                request.getJSONArray("turns").let { turns -> (0 until turns.length()).map { turns.getJSONObject(it).let { turn ->
                    ConversationTurn(turn.getString("speaker"), turn.getString("text")) } } },
                request.getJSONArray("recent_actions").let { actions -> (0 until actions.length()).map(actions::getString) },
                if (request.isNull("country")) null else request.getString("country"),
                request.optString("clarification_id").takeIf { it.isNotEmpty() },
                request.optString("selected_option_id").takeIf { it.isNotEmpty() },
                request.optString("timezone", "UTC")),
                if (row.isNull("receipt")) null else VoiceWire.response(row.getJSONObject("receipt")),
                if (row.isNull("structured")) null else row.getJSONObject("structured").let {
                    StructuredLibraryRequest(it.getString("action"), it.optionalInt("episode_id"), it.getBoolean("use_current"))
                }).also { saved -> saved.receipt?.let { saved.structured?.validate(it) } }
        }.also { require(it.map { entry -> entry.request.requestId }.distinct().size == it.size) }
    } }
    override suspend fun write(owner: String, requests: List<RecoverableVoiceRequest>) = withContext(Dispatchers.IO) { synchronized(lock) {
        val file = file(owner)
        if (requests.isEmpty()) { file.delete(); return@synchronized }
        require(requests.size <= 100)
        check(directory.isDirectory || directory.mkdirs())
        val entries = JSONArray().apply { requests.forEach { row ->
            put(JSONObject().put("request", VoiceWire.request(row.request).put("country", row.request.country))
                .put("receipt", row.receipt?.let(::response))
                .put("structured", row.structured?.let { JSONObject().put("action", it.action)
                    .put("episode_id", it.episodeId).put("use_current", it.useCurrent) }))
        } }
        // Older readers must reject typed records rather than reinterpret their labels as AI commands.
        val bytes = JSONObject().put("schema", 2).put("owner", owner).put("requests", entries).toString().toByteArray(Charsets.UTF_8)
        require(bytes.size <= 8 * 1024 * 1024) { "There are too many unfinished requests to save. Check an earlier request first." }
        val stream = file.startWrite()
        try { stream.write(bytes); file.finishWrite(stream) }
        catch (failure: Exception) { file.failWrite(stream); throw failure }
    } }
    private fun response(value: VoiceResponse): JSONObject = JSONObject().put("action", value.action.wire)
        .put("status", value.status).put("clarification", value.clarification?.let { question ->
            JSONObject().put("id", question.id).put("question", question.question).put("expires_at", question.expiresAt)
                .put("choices", JSONArray().apply { question.choices.forEach { put(JSONObject().put("id", it.id).put("label", it.label)) } })
        })
        .put("spoken_response", value.spokenResponse).put("speed", value.speed).put("expects_reply", value.expectsReply)
        .put("episode", value.episode?.let(::episode)).put("actions", JSONArray().apply { value.actions.forEach { put(response(it)) } })
    private fun episode(value: RemoteEpisode) = JSONObject().put("id", value.id).put("title", value.title)
        .put("description", value.description).put("feed_title", value.source).put("feed_url", value.feedUrl)
        .put("audio_url", value.audioUrl).put("link", value.link).put("duration_seconds", value.durationSeconds)
        .put("word_count", value.wordCount).put("position_seconds", value.positionSeconds).put("completed", value.completed)
        .put("dismissed", value.dismissed).put("content_id", value.contentId).put("capture_error", value.captureError)
        .put("published_at", value.publishedAt).put("image_url", value.imageUrl)
        .put("progress_revision", value.progressRevision)
        .put("article_bookmark", value.articleBookmark?.let { JSONObject().put("text_version", it.textVersion).put("offset_utf16", it.offsetUtf16) })
    private fun JSONObject.optionalInt(key: String) = if (isNull(key)) null else getInt(key).also { require(it > 0) }
    private companion object { val lock = Any() }
}
