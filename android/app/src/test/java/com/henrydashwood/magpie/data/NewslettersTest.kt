package com.henrydashwood.magpie.data

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.test.*
import kotlinx.coroutines.withContext
import org.junit.Assert.*
import org.junit.Test
import java.io.IOException

@OptIn(ExperimentalCoroutinesApi::class)
class NewslettersTest {
    private class Repository : NewsletterRepository {
        val sender = PendingNewsletter(10, "Morning news", "editor@example.com", 2, "Today's news", sessionRevision = 1)
        var addressGate: CompletableDeferred<Unit>? = null
        var pendingGate: CompletableDeferred<Unit>? = null
        var changeGate: CompletableDeferred<Unit>? = null
        var fail = false
        val changes = mutableListOf<String>()
        override suspend fun newsletterAddress(): NewsletterAddress {
            withContext(NonCancellable) { addressGate?.await() }
            if (fail) throw IOException()
            return NewsletterAddress("quiet-heron@magpie.example")
        }
        override suspend fun pendingNewsletters(): List<PendingNewsletter> {
            withContext(NonCancellable) { pendingGate?.await() }
            if (fail) throw IOException()
            return listOf(sender)
        }
        override suspend fun approveNewsletter(item: PendingNewsletter) {
            changes += "approve"; changeGate?.await(); if (fail) throw IOException()
        }
        override suspend fun blockNewsletter(item: PendingNewsletter) { changes += "block"; changeGate?.await(); if (fail) throw IOException() }
        override suspend fun signUpForNewsletter(url: String): NewsletterSignup = error("Not used")
    }
    @Test fun switchingAccountsDiscardsLateAddressesAndSenderLists() = runTest {
        val repo = Repository().apply { addressGate = CompletableDeferred(); pendingGate = CompletableDeferred() }
        val model = Newsletters(backgroundScope, repo); model.reset(1)
        model.loadAddress(); model.loadPending(); runCurrent()
        model.reset(2)
        repo.addressGate!!.complete(Unit); repo.pendingGate!!.complete(Unit); runCurrent()
        assertEquals(NewsletterState(revision = 2), model.state.value)
    }
    @Test fun senderChangesAreSerializedAndALateReadCannotRestoreAnApprovedSender() = runTest {
        val repo = Repository()
        val notices = mutableListOf<String>()
        val model = Newsletters(backgroundScope, repo, notices::add); model.reset(1)
        model.loadPending(); runCurrent()
        repo.pendingGate = CompletableDeferred(); model.loadPending(); runCurrent()
        repo.changeGate = CompletableDeferred(); model.approve(repo.sender); model.block(repo.sender); runCurrent()
        assertEquals(listOf("approve"), repo.changes)
        repo.changeGate!!.complete(Unit); runCurrent()
        repo.pendingGate!!.complete(Unit); runCurrent()
        assertTrue(model.state.value.pending.isEmpty()); assertNull(model.state.value.busyId)
        assertEquals(1, notices.size); assertTrue(notices.single().startsWith("Following"))
    }
    @Test fun failuresKeepTheSenderAvailableForRetryAndOldRowsCannotBeUsedAfterReset() = runTest {
        val repo = Repository(); val model = Newsletters(backgroundScope, repo); model.reset(1)
        model.loadPending(); runCurrent()
        repo.fail = true; model.block(repo.sender); runCurrent()
        assertEquals(listOf(repo.sender), model.state.value.pending); assertNotNull(model.state.value.pendingError)
        repo.fail = false; model.block(repo.sender); runCurrent()
        assertTrue(model.state.value.pending.isEmpty()); assertNull(model.state.value.pendingError)
        model.reset(2); model.approve(repo.sender); runCurrent()
        assertEquals(listOf("block", "block"), repo.changes)
    }
}
