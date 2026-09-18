package com.henrydashwood.magpie.telemetry

import com.henrydashwood.magpie.voice.LocalCommand
import org.junit.Assert.*
import org.junit.Test

class VoiceAttemptTest {
    @Test fun timingStartsAtCaptureAndPayloadOnlyContainsCoarseFacts() {
        var now = 0L; val events = mutableListOf<TelemetryEvent>()
        val attempt = VoiceAttempt(true, 2, true, "0.1", "1", { events += it }, { now })
        now = 1_000_000_000; attempt.listening()
        now = 3_000_000_000; attempt.captured(false); attempt.local(LocalCommand.Sleep(15)); attempt.answered()
        now = 4_000_000_000; attempt.finish(); attempt.finish()
        val fields = events.single().fields
        assertEquals(2.0, fields["listen_seconds"]); assertEquals(3.0, fields["capture_ended_seconds"])
        assertEquals(4.0, fields["total_seconds"]); assertEquals("sleep", fields["outcome"])
        assertEquals("set", fields["sleep_command"]); assertEquals(false, fields["command_sent"])
        assertEquals("android:1", fields["app_build"])
        assertFalse(fields.keys.any { it.contains("transcript") && it != "transcript_empty" })
    }
    @Test fun commandAndAttemptShareATraceButUseSeparateParentIds() {
        var event: TelemetryEvent? = null
        val attempt = VoiceAttempt(false, 0, false, "0.1", "1", { event = it })
        attempt.sent("request-uuid"); attempt.outcome = VoiceOutcome.Played; attempt.finish()
        val commandTrace = telemetryTrace("request-uuid")
        assertEquals(commandTrace.split('-')[1], event!!.traceparent!!.split('-')[1])
        assertNotEquals(commandTrace, event.traceparent)
        assertEquals(true, event.fields["command_sent"])
    }
    @Test fun failedDiagnosticSinkCannotBreakTheVoiceAction() {
        val attempt = VoiceAttempt(false, 0, true, "0.1", "1", { throw java.io.IOException("Storage unavailable") })
        attempt.finish()
    }
}
