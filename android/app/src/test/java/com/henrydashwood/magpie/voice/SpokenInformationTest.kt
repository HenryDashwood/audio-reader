package com.henrydashwood.magpie.voice

import kotlinx.coroutines.*
import kotlinx.coroutines.test.*
import org.junit.Assert.*
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class SpokenInformationTest {
    private class Host : VoiceHost {
        var held: String? = null
        val ended = mutableListOf<Boolean>()
        override fun account() = VoiceAccount("one", 1, true, null)
        override suspend fun begin(token: String, revision: Int) { held = token }
        override suspend fun end(token: String, resume: Boolean) { if (held == token) held = null; ended += resume }
        override fun valid(token: String, revision: Int) = held == token
        override suspend fun local(command: LocalCommand, token: String): LocalVoiceResult? = error("Must not interpret speech")
        override suspend fun consent(): Boolean = error("Must not use AI")
        override suspend fun allowAI() = error("Must not grant AI")
        override fun operation(request: VoiceRequest, revision: Int): VoiceOperation = error("Must not send a command")
        override suspend fun apply(response: VoiceResponse, token: String, revision: Int): Boolean = error("Must not apply commands")
    }
    @Test fun playbackResumesOnlyAfterTheSpokenAddressFinishes() = runTest {
        val host = Host(); val done = CompletableDeferred<Unit>(); val context = Conversation()
        val texts = mutableListOf<String>()
        val speech = SpokenInformation(backgroundScope, host, VoiceOutput { texts += it; done.await() }, context) { fail(it) }
        speech.speak("Address"); runCurrent()
        assertTrue(speech.speaking.value); assertTrue(context.executing); assertNotNull(host.held); assertTrue(host.ended.isEmpty())
        speech.speak("Duplicate"); done.complete(Unit); runCurrent()
        assertEquals(listOf("Address"), texts); assertEquals(listOf(true), host.ended)
        assertFalse(context.executing); assertFalse(speech.speaking.value)
    }
    @Test fun independentControlsAndAccountChangeStopSpeechWithoutResumingAudio() = runTest {
        val host = Host(); val context = Conversation(); var closed = false
        val speech = SpokenInformation(backgroundScope, host, VoiceOutput { try { awaitCancellation() } finally { closed = true } }, context) { fail(it) }
        speech.speak("Address"); runCurrent(); host.held = null; speech.playbackChanged(null); runCurrent()
        assertTrue(closed); assertEquals(listOf(false), host.ended); assertFalse(context.executing)
        speech.speak("Another address"); runCurrent(); speech.stop(resume = false); runCurrent()
        assertEquals(listOf(false, false), host.ended)
    }
    @Test fun busyConversationCannotBeInterruptedByAnAddressReadout() = runTest {
        val context = Conversation(); context.acquire("conversation")
        val host = Host(); val errors = mutableListOf<String>()
        val speech = SpokenInformation(backgroundScope, host, VoiceOutput { fail("Unexpected speech") }, context, errors::add)
        speech.speak("Address"); runCurrent()
        assertNull(host.held); assertTrue(host.ended.isEmpty()); assertTrue(context.executing)
        assertEquals(1, errors.size); assertFalse(speech.speaking.value)
    }
}
