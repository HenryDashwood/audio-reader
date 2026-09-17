package com.henrydashwood.magpie.voice

import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.test.*
import org.junit.Assert.*
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class VoiceSessionTest {
    private class Input : VoiceInput {
        val words = Channel<String?>(Channel.UNLIMITED)
        val waits = mutableListOf<Long>()
        var active = false
        var finishes = 0
        override suspend fun listen(firstWordsMs: Long, onReady: () -> Unit, onPartial: (String) -> Unit): String? {
            waits += firstWordsMs; active = true
            try { onReady(); return words.receive() } finally { active = false }
        }
        override fun finish() { finishes++ }
    }
    private class Host : VoiceHost {
        var account = VoiceAccount("one", 1, true, 42)
        var token: String? = null
        val ends = mutableListOf<Boolean>()
        val requests = mutableListOf<VoiceRequest>()
        val locals = mutableListOf<LocalCommand>()
        val applied = mutableListOf<VoiceResponse>()
        val reconciled = mutableListOf<VoiceResponse>()
        var allowed = true
        var grants = 0
        var cancelled = 0
        var gate: CompletableDeferred<Unit>? = null
        var response = VoiceResponse(VoiceAction.Unknown, "Which show?", expectsReply = true)
        var fail = false
        override fun account() = account
        override suspend fun begin(token: String, revision: Int) { this.token = token }
        override suspend fun end(token: String, resume: Boolean) { if (this.token == token) this.token = null; ends += resume }
        override fun valid(token: String, revision: Int) = this.token == token && account.revision == revision
        override suspend fun local(command: LocalCommand, token: String): LocalVoiceResult? {
            locals += command
            return when (command) {
                LocalCommand.Pause -> LocalVoiceResult(end = true)
                is LocalCommand.Sleep -> LocalVoiceResult("Sleep timer set.")
                else -> null
            }
        }
        override suspend fun consent() = allowed
        override suspend fun allowAI() { grants++; allowed = true }
        override fun operation(request: VoiceRequest, revision: Int) = object : VoiceOperation {
            override suspend fun response(onDelta: (String) -> Unit): VoiceResponse {
                requests += request; onDelta("A partial answer")
                gate?.await()
                if (fail) throw VoiceFailure("Disconnected")
                return response
            }
            override suspend fun cancel() { cancelled++ }
        }
        override suspend fun apply(response: VoiceResponse, token: String, revision: Int): Boolean {
            applied += response; return response.action == VoiceAction.Play
        }
        override suspend fun reconcile(response: VoiceResponse, token: String, revision: Int) { reconciled += response }
    }

    @Test fun replyMustFinishSpeakingBeforeAnyClientEffectsOrFollowUpMicrophone() = runTest {
        val host = Host(); val input = Input(); val spoken = CompletableDeferred<Unit>()
        val session = VoiceSession(this, host, input, { spoken.await() }, { ConversationPreferences() })
        session.open(7); input.words.trySend("Read this"); session.listen(); runCurrent()
        assertEquals(VoicePhase.Speaking, session.state.value.phase)
        assertFalse(input.active); assertTrue(host.applied.isEmpty()); assertEquals(listOf(8_000L), input.waits)
        assertEquals(1, host.reconciled.size)
        assertEquals(7, host.requests.single().viewedEpisodeId); assertEquals(42, host.requests.single().nowPlayingEpisodeId)
        assertTrue(host.requests.single().turns.isEmpty())
        spoken.complete(Unit); runCurrent()
        assertEquals(1, host.applied.size); assertTrue(input.active); assertEquals(listOf(8_000L, 15_000L), input.waits)
        session.close(); runCurrent(); assertFalse(input.active)
    }

    @Test fun cancellationDuringConfirmationRetainsOriginalRequestUntilSuccessfulRecovery() = runTest {
        val host = Host(); val input = Input(); var blocked = true
        val session = VoiceSession(this, host, input, { if (blocked) awaitCancellation() }, { ConversationPreferences(false) })
        session.open(7); session.submit("Read the news"); runCurrent()
        val original = host.requests.single()
        session.close(); runCurrent(); assertTrue(host.applied.isEmpty()); assertTrue(session.state.value.recoverable)
        blocked = false; session.open(99); session.retry(); runCurrent()
        assertSame(original, host.requests.single()); assertEquals(1, host.applied.size)
        assertFalse(session.state.value.recoverable); assertFalse(input.active)
    }

    @Test fun cancelledNetworkRequestUsesItsOwnOperationAndCannotApplyItsLateReply() = runTest {
        val host = Host().apply { gate = CompletableDeferred() }; val input = Input()
        val session = VoiceSession(this, host, input, {}, { ConversationPreferences(false) })
        session.open(null); session.submit("Find a show"); runCurrent(); session.close(); runCurrent()
        assertEquals(1, host.cancelled); assertTrue(host.applied.isEmpty())
        assertFalse(host.ends.last())
        host.gate!!.complete(Unit); runCurrent(); assertTrue(host.applied.isEmpty()); assertFalse(session.state.value.visible)
    }

    @Test fun accountChangeClearsHistoryAndPendingRequestsWithoutResumingOldAudio() = runTest {
        val host = Host().apply { gate = CompletableDeferred() }
        val session = VoiceSession(this, host, Input(), {}, { ConversationPreferences(false) })
        session.open(null); session.submit("Find a show"); runCurrent()
        host.account = VoiceAccount("two", 2, true, null); session.activate(); runCurrent()
        assertTrue(session.state.value.turns.isEmpty()); assertFalse(session.state.value.recoverable)
        assertFalse(host.ends.last()); host.gate!!.complete(Unit); runCurrent(); assertTrue(host.applied.isEmpty())
    }

    @Test fun consentMustBeExplicitAndDecliningDoesNotSendOrStoreARemoteRequest() = runTest {
        val host = Host().apply { allowed = false }
        val session = VoiceSession(this, host, Input(), {}, { ConversationPreferences(false) })
        session.open(3); session.submit("Find a new podcast"); runCurrent()
        assertEquals(VoicePhase.Consent, session.state.value.phase); assertTrue(host.requests.isEmpty()); assertEquals(0, host.grants)
        session.declineAI(); runCurrent(); assertTrue(host.requests.isEmpty())
        session.submit("Find a new podcast"); runCurrent(); session.allowAI(); runCurrent()
        assertEquals(1, host.grants); assertEquals("Find a new podcast", host.requests.single().transcript)
        assertEquals(1, session.state.value.turns.count { it.speaker == "her" })
    }

    @Test fun localCommandsWorkWithoutSignInOrConsentAndPauseClosesSilently() = runTest {
        val host = Host().apply { allowed = false; account = VoiceAccount(null, 1, false, null) }
        var spoken = 0
        val session = VoiceSession(this, host, Input(), { spoken++ }, { ConversationPreferences() })
        session.open(null); session.submit("Pause"); runCurrent()
        assertEquals(listOf(LocalCommand.Pause), host.locals); assertFalse(session.state.value.visible)
        assertEquals(0, spoken); assertTrue(host.requests.isEmpty())
    }

    @Test fun replyQuestionsAllowFollowUpButTalkBackAndTypedRequestsRequireAnExplicitTap() = runTest {
        val host = Host(); val input = Input()
        val session = VoiceSession(this, host, input, {}, { ConversationPreferences(false, 30) })
        session.open(null); input.words.trySend("Find a show"); session.listen(); runCurrent()
        assertEquals(listOf(8_000L, 30_000L), input.waits)
        session.close(); runCurrent(); session.open(null)
        input.words.trySend("Find another show"); session.listen(accessible = true); runCurrent()
        assertFalse(input.active); assertEquals(15_000L, input.waits.last())
        val before = input.waits.size; session.submit("Find a third show"); runCurrent(); assertEquals(before, input.waits.size)
    }

    @Test fun noSpeechInFollowUpEndsQuietlyAndEndPhraseSendsNoRequest() = runTest {
        val host = Host(); val input = Input()
        val session = VoiceSession(this, host, input, {}, { ConversationPreferences() })
        session.open(null); input.words.trySend("Find a show"); input.words.trySend(null); session.listen(); runCurrent()
        assertEquals(VoicePhase.Idle, session.state.value.phase); assertNull(session.state.value.error)
        session.submit("That's all"); runCurrent(); assertFalse(session.state.value.visible); assertEquals(1, host.requests.size)
    }

    @Test fun playbackChangesAndBackgroundingStopCaptureWithoutAutomaticRestart() = runTest {
        val host = Host(); val input = Input()
        val session = VoiceSession(this, host, input, {}, { ConversationPreferences() })
        session.open(null); session.listen(); runCurrent(); session.background(); runCurrent()
        assertTrue(session.state.value.visible); assertFalse(input.active); assertEquals(VoicePhase.Idle, session.state.value.phase)
        session.listen(); runCurrent(); host.token = null; session.playbackChanged(null); runCurrent()
        assertFalse(input.active); assertFalse(session.state.value.visible); assertFalse(host.ends.last())
    }

    @Test fun failedSpokenReplyKeepsReceiptRecoverableAndNeverAppliesPlayback() = runTest {
        val host = Host().apply { response = VoiceResponse(VoiceAction.Play, "Playing") }
        val session = VoiceSession(this, host, Input(), { throw VoiceFailure("Missing offline voice") }, { ConversationPreferences() })
        session.open(null); session.submit("Play the news"); runCurrent()
        assertTrue(host.applied.isEmpty()); assertTrue(session.state.value.recoverable)
        assertEquals("Missing offline voice", session.state.value.error)
    }

    @Test fun shortcutMicrophoneLaunchIsConsumedOnceAndNeverSurvivesClosingOrAccountChanges() = runTest {
        val host = Host(); val input = Input()
        val session = VoiceSession(this, host, input, {}, { ConversationPreferences() })
        session.open(null, listenOnOpen = true)
        val first = checkNotNull(session.state.value.launchListening)
        assertTrue(session.consumeLaunchListening(first)); assertFalse(session.consumeLaunchListening(first))
        assertFalse(input.active) // Only the foreground permission-aware UI can start capture.
        session.open(null, listenOnOpen = true)
        val oldPermission = session.microphoneRequestVersion
        session.background()
        assertNull(session.state.value.launchListening); assertFalse(session.acceptsMicrophoneRequest(oldPermission))
        session.open(null, listenOnOpen = true)
        val previousAccount = session.microphoneRequestVersion
        host.account = VoiceAccount("two", 2, true, null); session.activate()
        assertFalse(session.acceptsMicrophoneRequest(previousAccount)); assertNull(session.state.value.launchListening)
    }

    @Test fun typingOrOpeningAnotherConversationInvalidatesAnOutstandingMicrophonePermissionRequest() = runTest {
        val session = VoiceSession(this, Host(), Input(), {}, { ConversationPreferences(false) })
        session.open(null)
        val permission = session.microphoneRequestVersion
        assertTrue(session.acceptsMicrophoneRequest(permission))
        session.submit("Find a show"); runCurrent()
        assertFalse(session.acceptsMicrophoneRequest(permission))
        val next = session.microphoneRequestVersion
        session.open(null); assertFalse(session.acceptsMicrophoneRequest(next))
        session.close()
    }

    @Test fun reopeningBeforeCancellationFinishesCannotUndoAnExplicitNoResumeDecision() = runTest {
        val host = Host(); val input = Input()
        val session = VoiceSession(this, host, input, {}, { ConversationPreferences() })
        session.open(null); session.listen(); runCurrent(); assertTrue(input.active)
        session.close(resume = false); session.open(null); runCurrent()
        assertFalse(input.active); assertFalse(host.ends.last())
    }
}
