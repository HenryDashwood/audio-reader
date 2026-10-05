package com.henrydashwood.magpie.data

import android.app.DownloadManager
import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.storage.StorageManager
import androidx.core.content.edit
import androidx.core.net.toUri
import android.os.Environment
import androidx.core.content.getSystemService
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/**
 * Android's own download manager, so transfers carry on when Magpie is closed and honour a
 * per-download Wi-Fi requirement. Files land in app-specific storage, removed with the app.
 */
class SystemDownloadTransport(private val context: Context) : DownloadTransport {
    private val manager = checkNotNull(context.getSystemService<DownloadManager>())
    private val directory get() = context.getExternalFilesDir(Environment.DIRECTORY_PODCASTS)

    override fun start(request: DownloadTransferRequest): Long {
        checkNotNull(directory) { "Storage is not available." }
        val download = DownloadManager.Request(request.url.toUri())
            .setTitle(request.title)
            .setDescription("Magpie")
            .setDestinationInExternalFilesDir(context, Environment.DIRECTORY_PODCASTS, request.fileName)
            .setAllowedOverMetered(request.allowsCellular)
            .setAllowedOverRoaming(request.allowsCellular)
            // Her own downloads show their progress in the shade, where TalkBack can read it.
            .setNotificationVisibility(if (request.visible) DownloadManager.Request.VISIBILITY_VISIBLE
                else DownloadManager.Request.VISIBILITY_HIDDEN)
        return manager.enqueue(download)
    }

    override fun remove(ids: Collection<Long>) {
        if (ids.isNotEmpty()) manager.remove(*ids.toLongArray())
    }

    override fun query(ids: Collection<Long>): Map<Long, TransferStatus> {
        if (ids.isEmpty()) return emptyMap()
        val found = mutableMapOf<Long, TransferStatus>()
        manager.query(DownloadManager.Query().setFilterById(*ids.toLongArray()))?.use { cursor ->
            fun long(column: String) = cursor.getLong(cursor.getColumnIndexOrThrow(column))
            fun int(column: String) = cursor.getInt(cursor.getColumnIndexOrThrow(column))
            fun string(column: String) = cursor.getString(cursor.getColumnIndexOrThrow(column))
            while (cursor.moveToNext()) {
                val id = long(DownloadManager.COLUMN_ID)
                val reason = int(DownloadManager.COLUMN_REASON)
                found[id] = when (int(DownloadManager.COLUMN_STATUS)) {
                    DownloadManager.STATUS_PENDING -> TransferStatus.Pending(false)
                    DownloadManager.STATUS_PAUSED -> TransferStatus.Pending(reason == DownloadManager.PAUSED_QUEUED_FOR_WIFI)
                    DownloadManager.STATUS_RUNNING -> {
                        val total = long(DownloadManager.COLUMN_TOTAL_SIZE_BYTES)
                        val done = long(DownloadManager.COLUMN_BYTES_DOWNLOADED_SO_FAR)
                        TransferStatus.Running(if (total > 0) (done.toDouble() / total).coerceIn(0.0, 1.0) else 0.0)
                    }
                    DownloadManager.STATUS_SUCCESSFUL -> {
                        val path = string(DownloadManager.COLUMN_LOCAL_URI)?.toUri()?.path
                        if (path == null) TransferStatus.Failed("The episode could not be saved on this phone.")
                        else TransferStatus.Succeeded(path, File(path).length(), string(DownloadManager.COLUMN_MEDIA_TYPE))
                    }
                    else -> TransferStatus.Failed(explain(reason))
                }
            }
        }
        return ids.associateWith { found[it] ?: TransferStatus.Missing }
    }

    override fun deleteFile(path: String) { File(path).delete() }
    override fun fileExists(path: String) = File(path).isFile
    /** Includes cached data the system would clear to make room, as Android recommends. */
    override fun freeSpace(): Long? {
        val folder = directory ?: return null
        val storage = context.getSystemService<StorageManager>() ?: return folder.usableSpace
        return try { storage.getAllocatableBytes(storage.getUuidForPath(folder)) } catch (_: Exception) { folder.usableSpace }
    }

    private fun explain(reason: Int) = when (reason) {
        DownloadManager.ERROR_INSUFFICIENT_SPACE -> "There was not enough space on this phone."
        DownloadManager.ERROR_HTTP_DATA_ERROR, DownloadManager.ERROR_CANNOT_RESUME ->
            "The connection was lost before the episode finished downloading."
        in 400..599, DownloadManager.ERROR_UNHANDLED_HTTP_CODE, DownloadManager.ERROR_TOO_MANY_REDIRECTS ->
            "The podcast’s server would not send this episode."
        else -> "The episode could not be downloaded."
    }

    companion object {
        /** Metered includes mobile data and a phone's hotspot, which is what "Wi-Fi only" is protecting. */
        fun onMobileData(context: Context): Boolean {
            val connectivity = context.getSystemService<ConnectivityManager>() ?: return false
            val capabilities = connectivity.getNetworkCapabilities(connectivity.activeNetwork) ?: return false
            return !capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED)
        }
    }
}

class PreferencesDownloadSettingsStore(context: Context) : DownloadSettingsStore {
    private val preferences = context.getSharedPreferences("magpie_downloads", Context.MODE_PRIVATE)
    override fun load() = DownloadSettings(
        limitBytes = preferences.getLong("limit", DownloadSettings.DEFAULT_LIMIT).coerceAtLeast(0),
        automatic = preferences.getBoolean("automatic", true),
        perShow = preferences.getInt("per_show", 1).takeIf { it in DownloadSettings.perShowOptions } ?: 1,
        wifiOnly = preferences.getBoolean("wifi_only", true),
    )
    override fun save(settings: DownloadSettings) {
        preferences.edit {
            putLong("limit", settings.limitBytes).putBoolean("automatic", settings.automatic)
                .putInt("per_show", settings.perShow).putBoolean("wifi_only", settings.wifiOnly)
        }
    }
}

/** The manifest in private app storage, excluded from backup by the app's backup rules. */
class FileDownloadManifestStore(context: Context) : DownloadManifestStore {
    private val file = File(context.filesDir, "downloads/manifest.json")

    override fun load(): DownloadManifest = try {
        if (!file.isFile) DownloadManifest() else decode(JSONObject(file.readText()))
    } catch (_: Exception) {
        // Without the manifest the files cannot be attributed to an account; they are deleted rather
        // than guessed at. The system rows are left to the next clear.
        file.delete()
        DownloadManifest()
    }

    override fun save(manifest: DownloadManifest) {
        file.parentFile?.mkdirs()
        val temporary = File(file.parentFile, "manifest.json.tmp")
        temporary.writeText(encode(manifest).toString())
        if (!temporary.renameTo(file)) { file.delete(); check(temporary.renameTo(file)) }
    }

    private fun encode(manifest: DownloadManifest) = JSONObject().put("schema", 1).put("owner", manifest.owner)
        .put("epoch", manifest.epoch).put("records", JSONArray(manifest.records.map { record ->
            val episode = record.episode
            JSONObject().put("id", episode.id).put("episode_id", episode.episodeId).put("title", episode.title)
                .put("source", episode.source).put("source_id", episode.sourceId).put("audio_url", episode.audioUrl)
                .put("duration_seconds", episode.durationSeconds).put("image_url", episode.imageUrl)
                .put("published_at", episode.publishedAt).put("description", episode.description)
                .put("origin", record.origin.name).put("bytes", record.bytes).put("requested_at", record.requestedAt)
                .put("played_at", record.playedAt).put("transfer_id", record.transferId).put("path", record.path)
                .put("allows_cellular", record.allowsCellular)
                .put("status", when (val status = record.status) {
                    is DownloadStatus.Queued -> if (status.waitingForWifi) "wifi" else "queued"
                    is DownloadStatus.Downloading -> "downloading"
                    DownloadStatus.Downloaded -> "downloaded"
                    is DownloadStatus.Failed -> "failed"
                })
                .put("failure", (record.status as? DownloadStatus.Failed)?.message)
        }))

    private fun decode(json: JSONObject): DownloadManifest {
        check(json.getInt("schema") == 1)
        val rows = json.getJSONArray("records")
        return DownloadManifest(json.optString("owner").takeIf { json.has("owner") && !json.isNull("owner") },
            json.getString("epoch"), (0 until rows.length()).map { index ->
                val row = rows.getJSONObject(index)
                fun text(name: String) = if (row.isNull(name)) null else row.optString(name)
                fun number(name: String) = if (row.isNull(name)) null else row.optLong(name)
                DownloadRecord(
                    DownloadedEpisode(row.getString("id"), number("episode_id")?.toInt(), row.getString("title"),
                        row.getString("source"), row.getString("source_id"), row.getString("audio_url"),
                        number("duration_seconds")?.toInt(), text("image_url"), text("published_at"), row.optString("description")),
                    DownloadOrigin.valueOf(row.getString("origin")),
                    when (row.getString("status")) {
                        "wifi" -> DownloadStatus.Queued(true)
                        "queued", "downloading" -> DownloadStatus.Queued(false)
                        "downloaded" -> DownloadStatus.Downloaded
                        else -> DownloadStatus.Failed(text("failure") ?: "The episode could not be downloaded.")
                    },
                    row.getLong("bytes"), row.getLong("requested_at"), number("played_at"), number("transfer_id"),
                    text("path"), row.optBoolean("allows_cellular", true))
            })
    }
}
