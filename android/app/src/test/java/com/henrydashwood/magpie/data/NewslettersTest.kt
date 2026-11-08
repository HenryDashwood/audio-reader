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
        var pending = listOf(sender)
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
            return pending
        }
        private suspend fun change(action: String) {
            changes += action
            val shouldFail = fail
            withContext(NonCancellable) { changeGate?.await() }
            if (shouldFail) throw IOException()
        }
        override suspend fun approveNewsletter(item: PendingNewsletter) = change("approve")
        override suspend fun blockNewsletter(item: PendingNewsletter) = change("block")
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
    @Test fun lateRefreshAndRepeatedTapPreserveTheOtherSender() = runTest {
        for (block in listOf(false, true)) {
            val repo = Repository()
            val other = repo.sender.copy(id = 11, title = "Evening news")
            repo.pending = listOf(repo.sender, other)
            val notices = mutableListOf<String>()
            val model = Newsletters(backgroundScope, repo, notices::add)
            model.reset(1)
            model.loadPending()
            runCurrent()
            repo.pendingGate = CompletableDeferred()
            model.loadPending()
            runCurrent()

            fun answer() = if (block) model.block(repo.sender) else model.approve(repo.sender)
            answer()
            runCurrent()
            repo.pendingGate!!.complete(Unit)
            runCurrent()
            answer()
            runCurrent()

            assertEquals(listOf(other), model.state.value.pending)
            assertEquals(listOf(if (block) "block" else "approve"), repo.changes)
            assertEquals(1, notices.size)
        }
    }
    @Test fun lateFollowOrBlockAfterAccountSwitchOnlyAnnouncesTheNewAccountsDecision() = runTest {
        for (block in listOf(false, true)) for (fail in listOf(false, true)) {
            val repo = Repository()
            val notices = mutableListOf<String>()
            val model = Newsletters(backgroundScope, repo, notices::add)
            model.reset(1)
            model.loadPending()
            runCurrent()
            val original = CompletableDeferred<Unit>()
            repo.changeGate = original
            repo.fail = fail
            if (block) model.block(repo.sender) else model.approve(repo.sender)
            runCurrent()

            model.reset(2)
            val replacement = repo.sender.copy(sessionRevision = 2)
            repo.pending = listOf(replacement)
            repo.fail = false
            model.loadPending()
            runCurrent()
            model.block(repo.sender)
            val current = CompletableDeferred<Unit>()
            repo.changeGate = current
            model.block(replacement)
            runCurrent()

            original.complete(Unit)
            runCurrent()
            assertEquals(replacement.id, model.state.value.busyId)
            assertEquals(listOf(replacement), model.state.value.pending)
            assertNull(model.state.value.pendingError)
            assertTrue(notices.isEmpty())

            current.complete(Unit)
            runCurrent()
            assertEquals(listOf(if (block) "block" else "approve", "block"), repo.changes)
            assertEquals(listOf("Blocked Morning news."), notices)
            assertTrue(model.state.value.pending.isEmpty())
        }
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
