package com.henrydashwood.magpie.telemetry

import com.henrydashwood.magpie.BuildConfig
import com.henrydashwood.magpie.data.AccountLibrary
import com.henrydashwood.magpie.voice.VoiceAccount
import java.util.concurrent.atomic.AtomicBoolean

class LibraryVoiceTelemetry(private val library: AccountLibrary) : VoiceTelemetry {
    override fun begin(account: VoiceAccount, accessible: Boolean, conversationTurns: Int): VoiceAttempt? {
        val queue = library.telemetry ?: return null
        val session = library.telemetryScope() ?: return null
        if (!account.live || account.owner != session.owner || account.revision != session.revision) return null
        return VoiceAttempt(accessible, conversationTurns, !attempted.getAndSet(true), BuildConfig.VERSION_NAME,
            BuildConfig.VERSION_CODE.toString(), { event -> queue.record(event, session) })
    }
    companion object { private val attempted = AtomicBoolean(false) }
}
