package com.henrydashwood.magpie.data

import com.henrydashwood.magpie.voice.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.util.UUID

enum class ItemFilingAction(val route: String) { Finish("mark_played"), Restore("restore"), Dismiss("dismiss") }
data class ItemFilingState(val item: LibraryItem? = null, val action: ItemFilingAction? = null,
    val busy: Boolean = false, val error: String? = null)

/** Explicit row actions share the assistant's durable request IDs and playback hold. */
class ItemFiling(private val scope: CoroutineScope, private val library: AccountLibrary,
    private val host: VoiceHost, private val notice: (String) -> Unit) {
    private val mutable = MutableStateFlow(ItemFilingState())
    val state = mutable.asStateFlow()
    private var job: Job? = null
    private var generation = 0

    fun reset() { generation++; job?.cancel(); job = null; mutable.value = ItemFilingState() }
    fun dismissError() { if (!state.value.busy) mutable.value = ItemFilingState() }
    fun retry() { val pending = state.value; pending.item?.let { file(it, checkNotNull(pending.action)) } }

    fun file(item: LibraryItem, action: ItemFilingAction) {
        if (state.value.busy) return
        val account = library.state.value
        if (!account.live || item.episodeId == null || account.items.none { it.id == item.id && it.contentId == item.contentId }) return
        val version = generation
        mutable.value = ItemFilingState(item, action, busy = true)
        job = scope.launch {
            val token = UUID.randomUUID().toString()
            var acquired = false
            var safeToResume = true
            var operation: VoiceOperation? = null
            fun checkCurrent() {
                if (version != generation || library.state.value.revision != account.revision ||
                    library.state.value.owner != account.owner || acquired && !host.valid(token, account.revision))
                    throw CancellationException("Listening or account changed")
            }
            try {
                var historical = false
                val label = when (action) {
                    ItemFilingAction.Finish -> if (item.kind == ContentKind.Article) "Mark as read" else "Mark as played"
                    ItemFilingAction.Restore -> "Restore item"
                    ItemFilingAction.Dismiss -> "Dismiss from Latest"
                } + ": ${item.title}"
                val response = withTimeout(30_000) {
                    library.actions.run(action.route, item.episodeId, label = label.take(2_000),
                        before = { requestId ->
                            checkCurrent()
                            library.holdProgress(setOf(item.episodeId), requestId)
                            host.begin(token, account.revision); acquired = true
                            host.prepareRequest(VoiceRequest(label.take(2_000), requestId, viewedEpisodeId = item.episodeId), token)
                            checkCurrent()
                        }, send = { requestId ->
                            safeToResume = false
                            library.speedUndo = null
                            val request = library.libraryAction(action.route, item.episodeId, requestId, account.revision)
                            operation = request
                            request.response().also { operation = null }
                        }, reconcile = { receipt ->
                            safeToResume = false; checkCurrent()
                            host.reconcile(receipt, token, account.revision); checkCurrent()
                            safeToResume = true
                        }, reconcileRecovered = { receipt ->
                            safeToResume = false; checkCurrent()
                            host.reconcileRecovered(receipt, token, account.revision); checkCurrent()
                            historical = true; safeToResume = true
                        })
                }
                checkCurrent()
                mutable.value = ItemFilingState()
                notice(if (historical) response.recoveryMessage else response.spokenResponse)
            } catch (failure: Exception) {
                if (version == generation && library.state.value.revision == account.revision) {
                    mutable.value = ItemFilingState(item, action, error =
                        "Could not confirm the change to ${item.title}. Try again, or open Ask Magpie to check saved requests.")
                }
                if (failure is CancellationException && failure !is TimeoutCancellationException) throw failure
            } finally {
                withContext(NonCancellable) {
                    withTimeoutOrNull(5_000) { operation?.let { runCatching { it.cancel() } } }
                    if (acquired) withTimeoutOrNull(5_000) { runCatching { host.end(token, safeToResume) } }
                }
            }
        }
    }
}
