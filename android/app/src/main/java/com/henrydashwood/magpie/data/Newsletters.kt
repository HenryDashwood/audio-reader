package com.henrydashwood.magpie.data

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

data class NewsletterState(val revision: Int = -1, val address: NewsletterAddress? = null,
    val loadingAddress: Boolean = false, val addressError: String? = null,
    val pending: List<PendingNewsletter> = emptyList(), val loadingPending: Boolean = false,
    val busyId: Int? = null, val pendingError: String? = null)

/** Address and sender state is discarded when the account session changes. */
class Newsletters(private val scope: CoroutineScope, private val repository: NewsletterRepository,
    private val announce: (String) -> Unit = {}) {
    private val mutable = MutableStateFlow(NewsletterState())
    val state = mutable.asStateFlow()
    private var generation = 0
    private var addressVersion = 0
    private var pendingVersion = 0
    private var addressJob: Job? = null
    private var pendingJob: Job? = null
    private var changeJob: Job? = null

    fun reset(revision: Int) {
        generation++; addressVersion++; pendingVersion++
        addressJob?.cancel(); pendingJob?.cancel(); changeJob?.cancel()
        mutable.value = NewsletterState(revision)
    }
    fun loadAddress() {
        if (state.value.loadingAddress || state.value.address != null) return
        val account = generation
        val request = ++addressVersion
        mutable.value = state.value.copy(loadingAddress = true, addressError = null)
        addressJob = scope.launch {
            fun update(work: (NewsletterState) -> NewsletterState) {
                if (account == generation && request == addressVersion) mutable.value = work(state.value)
            }
            try { val address = repository.newsletterAddress(); update { it.copy(address = address) } }
            catch (cancelled: CancellationException) { throw cancelled }
            catch (failure: Exception) { update { it.copy(addressError = AccountLibrary.message(failure)) } }
            finally { update { it.copy(loadingAddress = false) } }
        }
    }
    fun loadPending() {
        if (state.value.busyId != null) return
        pendingJob?.cancel()
        val account = generation
        val request = ++pendingVersion
        mutable.value = state.value.copy(loadingPending = true, pendingError = null)
        pendingJob = scope.launch {
            fun update(work: (NewsletterState) -> NewsletterState) {
                if (account == generation && request == pendingVersion) mutable.value = work(state.value)
            }
            try { val pending = repository.pendingNewsletters(); update { it.copy(pending = pending) } }
            catch (cancelled: CancellationException) { throw cancelled }
            catch (failure: Exception) { update { it.copy(pendingError = AccountLibrary.message(failure)) } }
            finally { update { it.copy(loadingPending = false) } }
        }
    }
    fun approve(item: PendingNewsletter) = change(item, block = false)
    fun block(item: PendingNewsletter) = change(item, block = true)
    private fun change(item: PendingNewsletter, block: Boolean) {
        if (state.value.busyId != null || item.sessionRevision != state.value.revision || item !in state.value.pending) return
        val account = generation
        pendingVersion++; pendingJob?.cancel()
        mutable.value = state.value.copy(busyId = item.id, loadingPending = false, pendingError = null)
        changeJob = scope.launch {
            fun update(work: (NewsletterState) -> NewsletterState) {
                if (account == generation) mutable.value = work(state.value)
            }
            try {
                if (block) repository.blockNewsletter(item) else repository.approveNewsletter(item)
                if (account == generation) {
                    update { it.copy(pending = it.pending.filterNot { row -> row.id == item.id }) }
                    announce(if (block) "Blocked ${item.title}." else "Following ${item.title}. ${item.messageCountLabel} now in Latest.")
                }
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (failure: Exception) { update { it.copy(pendingError = AccountLibrary.message(failure)) } }
            finally { update { it.copy(busyId = null) } }
        }
    }
}
