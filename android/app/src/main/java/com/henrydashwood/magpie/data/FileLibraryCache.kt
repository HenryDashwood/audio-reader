package com.henrydashwood.magpie.data

import android.content.Context
import android.util.AtomicFile
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.FileNotFoundException

/** App-private, excluded from backup, with atomic replacement and serialized file access. */
class FileLibraryCache(private val directory: File) : LibraryCache {
    constructor(context: Context) : this(File(context.noBackupFilesDir, "library"))
    private fun file(owner: String): AtomicFile {
        require(owner.matches(Regex("[a-f0-9]{64}")))
        return AtomicFile(File(directory, "$owner.json"))
    }
    override suspend fun load(owner: String): LibrarySnapshot? = withContext(Dispatchers.IO) { synchronized(lock) {
        val file = file(owner)
        try {
            val value = decode(JSONObject(file.openRead().bufferedReader().use { it.readText() }))
            require(value.owner == owner)
            value.restore(0) // Reject foreign item IDs and dangling list references before returning anything.
            value
        } catch (_: FileNotFoundException) { null }
        catch (_: Exception) { file.delete(); null }
    } }
    override suspend fun save(snapshot: LibrarySnapshot) = withContext(Dispatchers.IO) { synchronized(lock) {
        snapshot.restore(0)
        check(directory.isDirectory || directory.mkdirs()) { "Could not create offline library storage." }
        val file = file(snapshot.owner)
        val stream = file.startWrite()
        try { stream.write(encode(snapshot).toString().toByteArray(Charsets.UTF_8)); file.finishWrite(stream) }
        catch (failure: Exception) { file.failWrite(stream); throw failure }
    } }
    override suspend fun clear(owner: String) = withContext(Dispatchers.IO) { synchronized(lock) { file(owner).delete() } }

    private fun encode(value: LibrarySnapshot) = JSONObject().put("schema", 1).put("owner", value.owner)
        .put("items", JSONArray().apply { value.items.forEach { put(item(it)) } })
        .put("feeds", JSONArray().apply { value.feeds.forEach { put(feed(it)) } })
        .put("latest", JSONArray(value.latestIds)).put("saved", JSONArray(value.savedIds))
        .put("feed_items", JSONObject().apply { value.feedItems.forEach { (id, items) -> put(id, JSONArray(items)) } })

    private fun item(it: LibraryItem) = JSONObject().put("id", it.id).put("source", it.source).put("title", it.title)
        .put("description", it.description).put("kind", it.kind.name).put("duration_label", it.durationLabel)
        .put("text", it.text).put("version", it.contentVersion).put("url", it.originalUrl).put("html", it.html)
        .put("episode_id", it.episodeId).put("content_id", it.contentId).put("source_id", it.sourceId)
        .put("audio", it.audioUrl).put("words", it.wordCount).put("loaded", it.textLoaded)
        .put("position", it.remotePositionMs).put("completed", it.completed).put("dismissed", it.dismissed)
        .put("published_at", it.publishedAt).put("image_url", it.imageUrl)
        .put("capture_error", it.captureError).put("duration", it.durationSeconds).put("progress_revision", it.progressRevision)
        .put("article_bookmark", it.articleBookmark?.let(::bookmark))
        .put("article_progress", it.articleProgress?.let { progress -> JSONObject()
            .put("text_version", progress.textVersion).put("content", progress.contentId).put("revision", progress.revision)
            .put("bookmark", progress.bookmark?.let(::bookmark)) })
    private fun feed(it: LibraryFeed) = JSONObject().put("id", it.id).put("title", it.title).put("count", it.count)
        .put("articles", it.articles).put("url", it.url).put("sources", JSONArray(it.sources)).put("description", it.description)
        .put("image_url", it.imageUrl).put("forwarded", it.forwarded).put("details", JSONArray().apply { it.sourceDetails.forEach { source ->
            put(JSONObject().put("id", source.id).put("title", source.title).put("url", source.url).put("type", source.type)
                .put("primary", source.primary).put("failing", source.failing))
        } })
    private fun decode(row: JSONObject): LibrarySnapshot {
        require(row.getInt("schema") == 1)
        val listings = row.getJSONObject("feed_items")
        return LibrarySnapshot(row.getString("owner"), row.getJSONArray("items").objects().map { item ->
            LibraryItem(id = item.getString("id"), source = item.getString("source"), title = item.getString("title"),
                description = item.getString("description"), kind = ContentKind.valueOf(item.getString("kind")),
                durationLabel = item.getString("duration_label"), text = item.getString("text"), contentVersion = item.getString("version"),
                originalUrl = item.stringOrNull("url"), html = item.stringOrNull("html"), episodeId = item.intOrNull("episode_id"),
                contentId = item.intOrNull("content_id"), sourceId = item.getString("source_id"), audioUrl = item.stringOrNull("audio"),
                wordCount = item.intOrNull("words"), textLoaded = item.getBoolean("loaded"), remotePositionMs = item.getLong("position"),
                completed = item.getBoolean("completed"), dismissed = item.getBoolean("dismissed"),
                captureError = item.stringOrNull("capture_error"), durationSeconds = item.intOrNull("duration"),
                progressRevision = item.stringOrNull("progress_revision"), publishedAt = item.stringOrNull("published_at"), imageUrl = item.stringOrNull("image_url"),
                articleBookmark = item.optJSONObject("article_bookmark")?.let(::decodeBookmark),
                articleProgress = item.optJSONObject("article_progress")?.let { progress ->
                    ArticleProgressState(progress.getString("text_version"), progress.intOrNull("content"), progress.getString("revision"),
                        progress.optJSONObject("bookmark")?.let(::decodeBookmark)) })
        }, row.getJSONArray("feeds").objects().map { feed ->
            LibraryFeed(feed.getString("id"), feed.getString("title"), feed.getInt("count"), feed.getBoolean("articles"),
                feed.stringOrNull("url"), feed.getJSONArray("sources").strings(), feed.stringOrNull("description"),
                feed.getJSONArray("details").objects().map { source -> FeedSource(source.getString("id"), source.getString("title"),
                    source.getString("url"), source.getString("type"), source.getBoolean("primary"), source.getBoolean("failing")) },
                feed.getBoolean("forwarded"), feed.stringOrNull("image_url"))
        }, row.getJSONArray("latest").strings(), row.getJSONArray("saved").strings(),
            listings.keys().asSequence().associateWith { listings.getJSONArray(it).strings() })
    }
    private fun bookmark(value: RemoteArticleBookmark) = JSONObject().put("text_version", value.textVersion).put("offset", value.offsetUtf16)
    private fun decodeBookmark(value: JSONObject) = RemoteArticleBookmark(value.getString("text_version"), value.getInt("offset"))
    private fun JSONObject.stringOrNull(key: String) = if (isNull(key)) null else getString(key)
    private fun JSONObject.intOrNull(key: String) = if (isNull(key)) null else getInt(key)
    private fun JSONArray.objects() = (0 until length()).map(::getJSONObject)
    private fun JSONArray.strings() = (0 until length()).map(::getString)
    private companion object { val lock = Any() }
}
