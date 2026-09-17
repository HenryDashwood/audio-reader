package com.henrydashwood.magpie.telemetry

import android.content.Context
import android.util.AtomicFile
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

class FileTelemetryStore(private val directory: File) : TelemetryStore {
    constructor(context: Context) : this(File(context.noBackupFilesDir, "diagnostics"))
    private fun file(owner: String): AtomicFile {
        require(owner.matches(Regex("[a-f0-9]{64}")))
        return AtomicFile(File(directory, "$owner.json"))
    }
    override suspend fun read(owner: String): TelemetrySnapshot = withContext(Dispatchers.IO) {
        val file = file(owner)
        if (!file.baseFile.exists()) return@withContext TelemetrySnapshot()
        require(file.baseFile.length() <= 128_000)
        val root = JSONObject(file.openRead().use { it.readBytes().toString(Charsets.UTF_8) })
        val events = root.getJSONArray("pending")
        val pending = (0 until events.length()).map { index ->
            val entry = events.getJSONObject(index)
            val fields = entry.getJSONObject("fields")
            TelemetryEvent(entry.getString("kind"), fields.keys().asSequence().associateWith { fields.get(it) },
                entry.optString("traceparent").takeIf { it.isNotBlank() }, entry.getString("id"), entry.getLong("created_at"))
        }
        val sent = root.getJSONArray("acknowledged")
        TelemetrySnapshot(pending, (0 until sent.length()).map { sent.getString(it) })
    }
    override suspend fun write(owner: String, snapshot: TelemetrySnapshot): Unit = withContext(Dispatchers.IO) {
        val file = file(owner)
        check(directory.isDirectory || directory.mkdirs())
        val bytes = JSONObject().put("pending", JSONArray().apply { snapshot.pending.forEach { event ->
            put(JSONObject().put("kind", event.kind).put("fields", JSONObject(event.fields))
                .put("traceparent", event.traceparent).put("id", event.id).put("created_at", event.createdAt))
        } }).put("acknowledged", JSONArray(snapshot.acknowledged)).toString().toByteArray()
        require(bytes.size <= 128_000)
        val output = file.startWrite()
        try { output.write(bytes); file.finishWrite(output) }
        catch (failure: Throwable) { file.failWrite(output); throw failure }
    }
    override suspend fun clear(): Unit = withContext(Dispatchers.IO) { check(!directory.exists() || directory.deleteRecursively()) }
}
