package com.henrydashwood.magpie.telemetry

import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.content.Context
import android.os.Build
import android.util.AtomicFile
import com.henrydashwood.magpie.BuildConfig
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.File
import java.time.Instant
import java.util.UUID

/** The OS receives only a random marker. Account/session attribution stays in private storage. */
data class ExitMarker(val nonce: String, val owner: String, val credentialFingerprint: String,
    val appVersion: String, val osVersion: String, val startedAt: Long)
data class ProcessExit(val nonce: String, val at: Long, val kind: String, val reason: String)
interface ExitHistory {
    fun mark(nonce: String?)
    fun recent(): List<ProcessExit>
}
class AndroidExitHistory(private val context: Context) : ExitHistory {
    private val manager get() = context.getSystemService(ActivityManager::class.java)
    override fun mark(nonce: String?) {
        manager.setProcessStateSummary(nonce?.let { "magpie:$it".toByteArray(Charsets.US_ASCII) })
    }
    override fun recent(): List<ProcessExit> = manager.getHistoricalProcessExitReasons(context.packageName, 0, 20).mapNotNull { exit ->
        if (exit.processName != context.packageName || exit.realUid != context.applicationInfo.uid) return@mapNotNull null
        val type = when (exit.reason) {
            ApplicationExitInfo.REASON_CRASH -> "crash" to "android_java_crash"
            ApplicationExitInfo.REASON_CRASH_NATIVE -> "crash" to "android_native_crash"
            ApplicationExitInfo.REASON_ANR -> "hang" to "android_anr"
            else -> return@mapNotNull null
        }
        val marker = exit.processStateSummary?.toString(Charsets.US_ASCII) ?: return@mapNotNull null
        if (!marker.matches(Regex("magpie:[a-f0-9-]{36}"))) return@mapNotNull null
        ProcessExit(marker.removePrefix("magpie:"), exit.timestamp, type.first, type.second)
    }
}
interface ExitMarkerStore {
    suspend fun read(): ExitMarker?
    suspend fun write(marker: ExitMarker)
    suspend fun clear()
}
class FileExitMarkerStore(private val file: File) : ExitMarkerStore {
    constructor(context: Context) : this(File(context.noBackupFilesDir, "diagnostics/exit-marker.json"))
    override suspend fun read(): ExitMarker? = withContext(Dispatchers.IO) {
        if (!file.exists()) return@withContext null
        require(file.length() <= 2_048)
        val root = JSONObject(AtomicFile(file).openRead().use { it.readBytes().toString(Charsets.UTF_8) })
        ExitMarker(root.getString("nonce"), root.getString("owner"), root.getString("credential"), root.getString("app"), root.getString("os"), root.getLong("started"))
    }
    override suspend fun write(marker: ExitMarker): Unit = withContext(Dispatchers.IO) {
        check(file.parentFile!!.isDirectory || file.parentFile!!.mkdirs())
        val atomic = AtomicFile(file)
        val output = atomic.startWrite()
        try {
            output.write(JSONObject().put("nonce", marker.nonce).put("owner", marker.owner).put("credential", marker.credentialFingerprint)
                .put("app", marker.appVersion).put("os", marker.osVersion).put("started", marker.startedAt).toString().toByteArray())
            atomic.finishWrite(output)
        } catch (error: Throwable) { atomic.failWrite(output); throw error }
    }
    override suspend fun clear(): Unit = withContext(Dispatchers.IO) { AtomicFile(file).delete() }
}

/** Called serially by collectLatest on account changes; it never inspects raw traces. */
class AndroidExitReporter(private val current: () -> TelemetryScope?, private val signedIn: () -> Boolean,
    private val queue: TelemetryQueue, private val markers: ExitMarkerStore, private val history: ExitHistory,
    private val now: () -> Long = System::currentTimeMillis,
    private val appVersion: String = "${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE})",
    private val osVersion: String = "Android ${Build.VERSION.RELEASE}") {
    private var active: TelemetryScope? = null
    suspend fun update() {
        val session = current()
        if (session == null) {
            active = null
            withContext(Dispatchers.IO) { runCatching { history.mark(null) } }
            if (!signedIn()) runCatching { markers.clear() }
            return
        }
        if (session == active) return
        try {
            val previous = markers.read()
            if (previous != null && previous.owner == session.owner && previous.credentialFingerprint == session.credentialFingerprint) {
                val exits = withContext(Dispatchers.IO) { history.recent() }
                for (exit in exits) {
                    if (exit.nonce != previous.nonce || exit.at !in maxOf(previous.startedAt, now() - 30L * 86_400_000)..now()) continue
                    val fields = mapOf("kind" to exit.kind, "termination_reason" to exit.reason,
                        "app_version" to previous.appVersion, "os_version" to previous.osVersion,
                        "window_end" to Instant.ofEpochMilli(exit.at).toString())
                    if (!queue.enqueue(TelemetryEvent("diagnostic", fields, id = "${exit.nonce}-${exit.at}", createdAt = now()), session)) return
                }
            }
            if (current() != session) return
            val marker = ExitMarker(UUID.randomUUID().toString(), session.owner, session.credentialFingerprint, appVersion, osVersion, now())
            markers.write(marker)
            if (current() != session) return
            withContext(Dispatchers.IO) { history.mark(marker.nonce) }
            active = session
            queue.flush()
        } finally {
            if (current() != session) withContext(NonCancellable) {
                runCatching { markers.clear() }
                withContext(Dispatchers.IO) { runCatching { history.mark(null) } }
            }
        }
    }
}
