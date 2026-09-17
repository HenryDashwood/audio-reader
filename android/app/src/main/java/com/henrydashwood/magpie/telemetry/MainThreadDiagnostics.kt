package com.henrydashwood.magpie.telemetry

import android.app.Application
import android.os.Debug
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.os.SystemClock
import kotlinx.coroutines.*
import java.time.Instant
import java.util.concurrent.atomic.AtomicReference

/** A delayed acknowledgement is useful only if it still belongs to the same visible session. */
fun mainThreadHangSeconds(start: Long, end: Long, visible: Boolean, sameSession: Boolean): Double? =
    if (visible && sameSession && end - start >= 5_000) (end - start) / 1_000.0 else null

/** Detects recoverable foreground freezes too; fatal ANRs are collected after restart. */
class MainThreadDiagnostics(private val application: Application, private val queue: TelemetryQueue,
    private val current: () -> TelemetryScope?, private val scope: CoroutineScope,
    private val appVersion: String, private val osVersion: String, private val visible: () -> Boolean) {
    private var watching: Job? = null
    private val session = AtomicReference<TelemetryScope?>()
    private val main = Handler(Looper.getMainLooper())
    private val power = application.getSystemService(PowerManager::class.java)
    fun updateSession() { session.set(current()) }
    fun start() {
        watching = scope.launch(Dispatchers.Default) {
            while (isActive) {
                delay(1_000)
                val owner = session.get() ?: continue
                if (!visible() || !power.isInteractive || Debug.isDebuggerConnected()) continue
                val started = SystemClock.elapsedRealtime()
                val acknowledgement = CompletableDeferred<Long>()
                main.post { acknowledgement.complete(SystemClock.elapsedRealtime()) }
                val ended = acknowledgement.await()
                val seconds = mainThreadHangSeconds(started, ended,
                    visible() && power.isInteractive && !Debug.isDebuggerConnected(), owner == session.get()) ?: continue
                withContext(Dispatchers.Main.immediate) {
                    if (current() == owner) queue.record(TelemetryEvent("diagnostic", mapOf("kind" to "hang",
                        "termination_reason" to "android_main_thread_unresponsive", "hang_seconds" to seconds,
                        "app_version" to appVersion, "os_version" to osVersion, "window_end" to Instant.now().toString())), owner)
                }
            }
        }
    }
    fun stop() { watching?.cancel() }
}
