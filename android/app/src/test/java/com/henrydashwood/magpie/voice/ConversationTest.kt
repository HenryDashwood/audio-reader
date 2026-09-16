package com.henrydashwood.magpie.voice

import org.junit.Assert.*
import org.junit.Test

class ConversationTest {
    @Test fun requestsSendHistoryWithoutDuplicatingTheirOwnTranscript() {
        val context = Conversation().apply { activate("server:alice") }
        val first = context.request("Play history", playingEpisodeId = 10, viewedEpisodeId = 20, country = "GB")
        assertTrue(first.turns.isEmpty()); assertEquals(10, first.nowPlayingEpisodeId); assertEquals(20, first.viewedEpisodeId)
        context.appSaid("Which show?")
        val next = context.request("The Rest Is History")
        assertEquals(listOf("Play history", "Which show?"), next.turns.map { it.text })
        assertEquals("The Rest Is History", context.turns.last().text)
        assertNotEquals(first.requestId, next.requestId)
    }
    @Test fun staleConversationExpiresButUncertainRequestRemainsRecoverable() {
        var now = 0L
        val context = Conversation { now }.apply { activate("server:alice") }
        val first = context.request("Subscribe to history")
        context.appSaid("One moment")
        now = 120_001
        val retry = context.request("try again", recover = true)
        assertEquals(first, retry)
        assertEquals(listOf(ConversationTurn("her", "try again")), context.turns)
        context.applied(retry, "server:alice", listOf("subscribed: History"))
        assertNull(context.pending)
        assertEquals(listOf("subscribed: History"), context.recentActions)
    }
    @Test fun historyAndActionMemoryAreBoundedIndependentlyOfVisibleTranscript() {
        val context = Conversation().apply { activate("server:alice") }
        repeat(12) { context.appSaid("Reply $it") }
        val request = context.request("Next")
        assertEquals(8, request.turns.size); assertEquals("Reply 4", request.turns.first().text)
        assertEquals(13, context.turns.size)
        context.applied(request, "server:alice", (1..12).map { "action $it" })
        assertEquals((5..12).map { "action $it" }, context.request("Again").recentActions)
    }
    @Test fun accountOrServerChangeDropsPrivateContextAndRejectsLateReceipts() {
        val context = Conversation().apply { activate("staging:alice") }
        val first = context.request("Private request")
        val generation = context.generation()
        context.activate("production:alice")
        assertTrue(context.turns.isEmpty()); assertNull(context.pending)
        assertTrue(context.generation() > generation)
        context.applied(first, "staging:alice", listOf("private action"))
        assertTrue(context.recentActions.isEmpty())
        val other = context.request("Another request")
        context.activate(null)
        context.applied(other, "production:alice", listOf("another action"))
        assertTrue(context.recentActions.isEmpty()); assertNull(context.pending)
    }
    @Test fun oldRequestCannotClearANewerPendingRequestInTheSameAccount() {
        val context = Conversation().apply { activate("alice") }
        val first = context.request("First")
        val next = context.request("Second")
        context.applied(first, "alice", listOf("stale"))
        assertEquals(next, context.pending); assertTrue(context.recentActions.isEmpty())
    }
    @Test fun invalidRequestsAndPreferencesFailBeforeAnyNetworkWork() {
        listOf("", " ", "x".repeat(2001)).forEach { assertTrue(runCatching { VoiceRequest(it) }.isFailure) }
        assertTrue(runCatching { VoiceRequest("test", requestId = "../bad") }.isFailure)
        assertTrue(runCatching { VoiceRequest("test", country = "England") }.isFailure)
        assertEquals(15, ConversationPreferences().followUpSeconds)
        assertTrue(ConversationPreferences().keepListening)
        ConversationPreferences.waitOptions.forEach { assertEquals(it, ConversationPreferences(followUpSeconds = it).followUpSeconds) }
        assertTrue(runCatching { ConversationPreferences(followUpSeconds = 45) }.isFailure)
    }
}
