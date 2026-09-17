package com.henrydashwood.magpie.telemetry

import kotlinx.coroutines.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.util.UUID

/** No tokens, transcripts, titles, URLs, exception messages or stack traces belong here. */
data class TelemetryEvent(val kind: String, val fields: Map<String, Any>, val traceparent: String? = null,
    val id: String = UUID.randomUUID().toString(), val createdAt: Long = System.currentTimeMillis()) {
    init {
        require(kind in setOf("voice", "diagnostic"))
        require(id.matches(Regex("[a-zA-Z0-9-]{1,80}")))
        val allowed = if (kind == "voice") VOICE_FIELDS else DIAGNOSTIC_FIELDS
        require(fields.keys.all { it in allowed })
        require(fields.values.all { it is Boolean || it is Int || it is Long || it is Double && it.isFinite() || it is String && it.length <= 128 })
        require(traceparent == null || traceparent.matches(Regex("00-[a-f0-9]{32}-[a-f0-9]{16}-01")))
    }
    companion object {
        private val VOICE_FIELDS = setOf("outcome", "command_sent", "recogniser", "used_fallback", "listen_seconds", "capture_ended_seconds",
            "response_seconds", "transcript_empty", "settled_at_end", "transport_command", "sleep_command", "conversation_turns",
            "voiceover", "first_since_launch", "app_version", "app_build", "total_seconds", "error")
        private val DIAGNOSTIC_FIELDS = setOf("kind", "termination_reason", "hang_seconds", "app_version", "os_version", "window_end")
    }
}
data class TelemetryScope(val owner: String, val revision: Int, val credentialFingerprint: String)
data class TelemetrySnapshot(val pending: List<TelemetryEvent> = emptyList(), val acknowledged: List<String> = emptyList())
interface TelemetryStore {
    suspend fun read(owner: String): TelemetrySnapshot
    suspend fun write(owner: String, snapshot: TelemetrySnapshot)
    suspend fun clear()
}
interface TelemetryApi { suspend fun reportTelemetry(token: String, event: TelemetryEvent) }

/** Best effort, bounded and owned by the session that observed the event. */
class TelemetryQueue(private val store: TelemetryStore, private val current: () -> TelemetryScope?,
    private val send: suspend (TelemetryScope, TelemetryEvent) -> Unit,
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate),
    private val now: () -> Long = System::currentTimeMillis) {
    private val disk = Mutex()
    private var sending: Job? = null
    fun invalidate() { sending?.cancel(); sending = null }
    suspend fun clear() { invalidate(); disk.withLock { store.clear() } }
    fun record(event: TelemetryEvent, session: TelemetryScope? = current()) {
        session ?: return
        scope.launch {
            try { if (enqueue(event, session)) flush() }
            catch (cancelled: CancellationException) { throw cancelled }
            catch (_: Exception) { /* Diagnostics must never interrupt listening. */ }
        }
    }
    suspend fun enqueue(event: TelemetryEvent, session: TelemetryScope): Boolean = disk.withLock {
        if (current() != session) return@withLock false
        val snapshot = prune(store.read(session.owner))
        if (current() != session) return@withLock false
        if (event.id !in snapshot.acknowledged && snapshot.pending.none { it.id == event.id }) {
            store.write(session.owner, snapshot.copy(pending = (snapshot.pending + event).takeLast(50)))
        }
        current() == session
    }
    fun flush() {
        val session = current() ?: return
        if (sending?.isActive == true) return
        sending = scope.launch {
            try {
                while (current() == session) {
                    val next = disk.withLock {
                        val snapshot = prune(store.read(session.owner))
                        if (current() != session) return@withLock null
                        store.write(session.owner, snapshot)
                        snapshot.pending.firstOrNull()
                    } ?: break
                    if (current() != session) break
                    send(session, next)
                    if (current() != session) break
                    disk.withLock {
                        val snapshot = prune(store.read(session.owner))
                        if (current() == session) store.write(session.owner, snapshot.copy(
                            pending = snapshot.pending.filterNot { it.id == next.id },
                            acknowledged = (snapshot.acknowledged + next.id).takeLast(50)))
                    }
                }
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (_: Exception) { /* Retain the original event for the next foreground retry. */ }
        }
    }
    private fun prune(snapshot: TelemetrySnapshot) = snapshot.copy(
        pending = snapshot.pending.filter { it.createdAt in (now() - 30L * 86_400_000)..now() }.takeLast(50),
        acknowledged = snapshot.acknowledged.takeLast(50))
}

fun telemetryTrace(requestId: String): String {
    val trace = java.security.MessageDigest.getInstance("SHA-256").digest(requestId.toByteArray())
        .take(16).joinToString("") { "%02x".format(it) }
    return "00-$trace-${UUID.randomUUID().toString().replace("-", "").take(16)}-01"
}
