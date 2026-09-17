package com.henrydashwood.magpie.telemetry

import com.henrydashwood.magpie.voice.LocalCommand
import com.henrydashwood.magpie.voice.VoiceAccount
import java.util.UUID

fun interface VoiceTelemetry {
    fun begin(account: VoiceAccount, accessible: Boolean, conversationTurns: Int): VoiceAttempt?
    companion object { val NONE = VoiceTelemetry { _, _, _ -> null } }
}

enum class VoiceOutcome(val wire: String) {
    Abandoned("abandoned"), NoSpeech("no_speech"), PermissionDenied("permission_denied"), Error("error"),
    Timeout("timeout"), ConsentRequired("consent_required"), Played("played"), Spoken("spoken"),
    Transport("transport"), Sleep("sleep"), Speed("speed"), Ended("ended")
}
/** Only coarse fields are exposed; the words themselves never enter this object. */
class VoiceAttempt(private val accessible: Boolean, private val turns: Int, private val first: Boolean,
    private val appVersion: String, private val appBuild: String,
    private val report: (TelemetryEvent) -> Unit, private val clock: () -> Long = System::nanoTime) {
    private val started = clock()
    private var finished = false
    var outcome = VoiceOutcome.Abandoned
    private var commandSent = false
    private var trace = telemetryTrace(UUID.randomUUID().toString())
    private var listeningAt: Long? = null
    private var listened: Double? = null
    private var captureEnded: Double? = null
    private var response: Double? = null
    private var empty: Boolean? = null
    private var transport: String? = null
    private var sleep: String? = null
    private fun seconds() = ((clock() - started).coerceAtLeast(0) / 1_000_000_000.0)
    fun listening() { listeningAt = clock() }
    fun captured(isEmpty: Boolean) { captureEnded = seconds(); empty = isEmpty; listened = listeningAt?.let { (clock() - it).coerceAtLeast(0) / 1_000_000_000.0 } }
    fun sent(requestId: String) { commandSent = true; trace = telemetryTrace(requestId) }
    fun answered() { response = seconds() }
    fun local(command: LocalCommand) {
        when (command) {
            LocalCommand.Pause -> { outcome = VoiceOutcome.Transport; transport = "pause" }
            LocalCommand.Resume -> { outcome = VoiceOutcome.Transport; transport = "resume" }
            is LocalCommand.Seek -> { outcome = VoiceOutcome.Transport; transport = "seek" }
            is LocalCommand.Speed, is LocalCommand.AdjustSpeed -> outcome = VoiceOutcome.Speed
            is LocalCommand.Sleep -> { outcome = VoiceOutcome.Sleep; sleep = "set" }
            LocalCommand.CancelSleep -> { outcome = VoiceOutcome.Sleep; sleep = "cancel" }
            LocalCommand.EndConversation -> outcome = VoiceOutcome.Ended
            LocalCommand.Undo -> outcome = VoiceOutcome.Spoken
        }
    }
    fun finish() {
        if (finished) return
        finished = true
        val fields = mutableMapOf<String, Any>("outcome" to outcome.wire, "command_sent" to commandSent,
            "recogniser" to "android_on_device", "used_fallback" to false, "voiceover" to accessible,
            "conversation_turns" to turns, "first_since_launch" to first, "app_version" to appVersion,
            "app_build" to "android:$appBuild", "total_seconds" to seconds())
        captureEnded?.let { fields["capture_ended_seconds"] = it }
        listened?.let { fields["listen_seconds"] = it }
        response?.let { fields["response_seconds"] = it }
        empty?.let { fields["transcript_empty"] = it }
        transport?.let { fields["transport_command"] = it }; sleep?.let { fields["sleep_command"] = it }
        // Instrumentation must never turn a user action into a failure.
        runCatching { report(TelemetryEvent("voice", fields, trace)) }
    }
}
