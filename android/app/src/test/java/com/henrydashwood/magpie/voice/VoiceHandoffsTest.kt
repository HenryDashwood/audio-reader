package com.henrydashwood.magpie.voice

import org.junit.Assert.*
import org.junit.Test

class VoiceHandoffsTest {
    @Test fun continuationIsPrivateAccountBoundAndOneUse() {
        val handoffs = VoiceHandoffs()
        val id = handoffs.create("alice", 3, "Read the news")
        assertFalse(id.contains("news"))
        assertEquals(VoiceHandoffs.Request("Read the news", false), handoffs.consume(id, "alice", 3, null))
        assertTrue(runCatching { handoffs.consume(id, "alice", 3, null) }.isFailure)
        val other = handoffs.create("alice", 3, "Private text")
        assertTrue(runCatching { handoffs.consume(other, "bob", 3, null) }.isFailure)
        assertTrue(runCatching { handoffs.consume("forged", "alice", 3, null) }.isFailure)
    }
    @Test fun recoveryRequiresTheSamePendingRequestAndGeneration() {
        val handoffs = VoiceHandoffs()
        val id = handoffs.create("alice", 3, "File this", "original")
        assertTrue(handoffs.consume(id, "alice", 3, "original").recovering)
        for ((generation, pending) in listOf(4 to "original", 3 to "new", 3 to null)) {
            val stale = handoffs.create("alice", 3, "File this", "original")
            assertTrue(runCatching { handoffs.consume(stale, "alice", generation, pending) }.isFailure)
        }
    }
    @Test fun expirationAndAccountClearDiscardUnopenedRequests() {
        var now = 0L
        val handoffs = VoiceHandoffs { now }
        val id = handoffs.create("alice", 3, "Find this")
        now = 600_000
        assertTrue(runCatching { handoffs.consume(id, "alice", 3, null) }.isFailure)
        val another = handoffs.create("alice", 3, "Find this")
        handoffs.clear()
        assertTrue(runCatching { handoffs.consume(another, "alice", 3, null) }.isFailure)
    }
}
