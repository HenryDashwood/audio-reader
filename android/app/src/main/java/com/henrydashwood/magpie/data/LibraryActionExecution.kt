package com.henrydashwood.magpie.data

import com.henrydashwood.magpie.voice.VoiceAction
import com.henrydashwood.magpie.voice.VoiceResponse
import kotlinx.coroutines.CancellationException
import java.util.UUID

interface LibraryActionApi {
    suspend fun libraryAction(token: String, action: String, episodeId: Int?, requestId: String): VoiceResponse
    suspend fun cancelLibraryAction(token: String, requestId: String)
}

/** Main-dispatcher ownership shared by all structured action service instances.
 * Keep both uncertain requests and confirmed-but-unreconciled receipts for retry. */
class LibraryActionExecution(private val account: () -> String?) {
    private data class Pending(val account: String, val action: String, val episodeId: Int?, val useCurrent: Boolean,
        val requestId: String = UUID.randomUUID().toString(), var receipt: VoiceResponse? = null)
    private var pending: Pending? = null
    private var active: Pending? = null
    fun invalidate() { pending = null }
    fun pendingCurrentItem(action: String): Int? = pending?.takeIf {
        it.account == account() && it.action == action && it.useCurrent
    }?.episodeId

    suspend fun run(action: String, episodeId: Int?, before: suspend (String) -> Unit,
        send: suspend (String) -> VoiceResponse, reconcile: suspend (VoiceResponse) -> Unit,
        useCurrent: Boolean = false, startNewChange: Boolean = false): VoiceResponse {
        require(action in setOf("mark_played", "dismiss", "restore", "undo")) { "Choose played, dismissed, or restored." }
        require(if (action == "undo") episodeId == null else episodeId != null && episodeId > 0) { "Choose an item first." }
        val key = checkNotNull(account()) { "Open Magpie and sign in first." }
        check(active?.account != key) { "Magpie is already updating your library. Let it finish and try again." }
        val request = pending?.takeIf { !startNewChange && it.account == key && it.action == action && it.episodeId == episodeId && it.useCurrent == useCurrent }
            ?: Pending(key, action, episodeId, useCurrent)
        pending = request
        fun checkAccount() { if (account() != key) throw CancellationException("Account changed") }
        active = request
        try {
            before(request.requestId); checkAccount()
            val receipt = request.receipt ?: send(request.requestId).also { response ->
                checkAccount()
                require(response.actions.isEmpty() && response.action in setOf(VoiceAction.Played, VoiceAction.Dismiss, VoiceAction.Restore,
                    VoiceAction.Subscribed, VoiceAction.Unsubscribed, VoiceAction.Unknown)) { "The library response could not be confirmed." }
                if (action != "undo") require(response.action.wire == action && response.episode?.id == episodeId) { "The library response did not match the requested item." }
                request.receipt = response
            }
            reconcile(receipt); checkAccount()
            pending = null
            return receipt
        } finally { if (active === request) active = null }
    }
}
