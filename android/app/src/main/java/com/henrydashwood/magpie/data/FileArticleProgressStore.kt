package com.henrydashwood.magpie.data

import android.content.Context
import android.util.AtomicFile
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.FileNotFoundException

/** Small durable journal, separate from large article text snapshots. No credentials. */
class FileArticleProgressStore(private val directory: File) : ArticleProgressStore {
    constructor(context: Context) : this(File(context.noBackupFilesDir, "article-progress"))
    private fun file(owner: String): AtomicFile {
        require(owner.matches(Regex("[a-f0-9]{64}")))
        return AtomicFile(File(directory, "$owner.json"))
    }
    override suspend fun read(owner: String): List<QueuedArticleProgress> = withContext(Dispatchers.IO) { synchronized(lock) {
        val file = file(owner)
        val raw = try { file.openRead().bufferedReader().use { it.readText() } } catch (_: FileNotFoundException) { return@synchronized emptyList() }
        // A malformed journal must fail closed. Silently forgetting its filing
        // barriers could authorize old clocks; preserve the file for recovery.
        val root = JSONObject(raw)
        require(root.getInt("schema") == 1 && root.getString("owner") == owner)
        val rows = root.getJSONArray("entries")
        (0 until rows.length()).map { index -> rows.getJSONObject(index).let { row ->
            val pending = row.optJSONObject("pending")?.let { ArticleProgressReport(it.getString("revision"),
                it.getString("text_version"), it.nullableContent(), it.getInt("offset"), it.getBoolean("completed"), it.getString("id")) }
            QueuedArticleProgress(row.getInt("episode"), row.getString("playback"), row.getString("revision"),
                ArticleProgressSample(row.getString("text_version"), row.nullableContent(), row.getInt("offset"), row.getBoolean("completed")), pending,
                if (row.isNull("pending_playback")) null else row.getString("pending_playback"),
                row.getBoolean("sampled"), row.getBoolean("blocked"), row.getBoolean("dismissed"),
                row.getJSONArray("guards").let { guards -> (0 until guards.length()).map(guards::getString).toSet() })
        } }.also { require(it.map { row -> row.episodeId }.distinct().size == it.size) }
    } }
    override suspend fun write(owner: String, entries: List<QueuedArticleProgress>) = withContext(Dispatchers.IO) { synchronized(lock) {
        val file = file(owner)
        if (entries.isEmpty()) { file.delete(); return@synchronized }
        check(directory.isDirectory || directory.mkdirs())
        val rows = JSONArray().apply { entries.forEach { entry ->
            put(JSONObject().put("episode", entry.episodeId).put("playback", entry.playbackId)
                .put("revision", entry.baselineRevision).put("text_version", entry.latest.textVersion).put("content", entry.latest.contentId).put("offset", entry.latest.offsetUtf16).put("completed", entry.latest.completed)
                .put("guards", JSONArray(entry.guards.toList())).put("sampled", entry.sampled).put("blocked", entry.blocked).put("dismissed", entry.dismissed)
                .put("pending_playback", entry.pendingPlaybackId).put("pending", entry.pending?.let {
                    JSONObject().put("revision", it.expectedRevision).put("text_version", it.textVersion).put("content", it.contentId).put("offset", it.offsetUtf16).put("completed", it.completed).put("id", it.requestId)
                }))
        } }
        val stream = file.startWrite()
        try {
            stream.write(JSONObject().put("schema", 1).put("owner", owner).put("entries", rows).toString().toByteArray(Charsets.UTF_8))
            file.finishWrite(stream)
        } catch (failure: Exception) { file.failWrite(stream); throw failure }
    } }
    private fun JSONObject.nullableContent() = if (isNull("content")) null else getInt("content")
    private companion object { val lock = Any() }
}
