package com.henrydashwood.magpie.data

import com.henrydashwood.magpie.voice.*
import kotlinx.coroutines.CancellationException
import java.util.UUID

interface LibraryActionApi {
    suspend fun libraryAction(token: String, action: String, episodeId: Int?, requestId: String): VoiceResponse
    suspend fun cancelLibraryAction(token: String, requestId: String)
}

/** Main-dispatcher ownership shared by all structured action service instances.
 * Keep both uncertain requests and confirmed-but-unreconciled receipts for retry. */
class LibraryActionExecution(private val conversation: Conversation = Conversation(),
    private val storageOwner: (() -> String?)? = null, private val account: () -> String?) {
    fun invalidate() { conversation.activate(null) }
    private suspend fun restore(key: String) {
        conversation.restore(checkNotNull(storageOwner?.invoke() ?: key))
        if (account() != key) throw CancellationException("Account changed")
    }
    suspend fun pendingCurrentItem(action: String): Int? {
        val key = account() ?: return null
        conversation.activate(key)
        check(!conversation.executing) { "Magpie is already handling a request. Let it finish and try again." }
        restore(key)
        return conversation.unfinished(action, useCurrent = true, anyCurrent = true)?.let {
            conversation.structured(it.requestId)?.episodeId
        }
    }

    suspend fun run(action: String, episodeId: Int?, before: suspend (String) -> Unit,
        send: suspend (String) -> VoiceResponse, reconcile: suspend (VoiceResponse) -> Unit,
        useCurrent: Boolean = false, startNewChange: Boolean = false,
        label: String = when (action) { "mark_played" -> "Mark item as played"; "dismiss" -> "Dismiss item"; "restore" -> "Restore item"; else -> "Undo the last library change" },
        reconcileRecovered: suspend (VoiceResponse) -> Unit = reconcile): VoiceResponse {
        val structured = StructuredLibraryRequest(action, episodeId, useCurrent)
        val key = checkNotNull(account()) { "Open Magpie and sign in first." }
        conversation.activate(key)
        val lease = UUID.randomUUID().toString()
        check(conversation.acquire(lease)) { "Magpie is already handling a request. Let it finish and try again." }
        fun checkAccount() { if (account() != key) throw CancellationException("Account changed") }
        try {
            restore(key)
            val owner = checkNotNull(storageOwner?.invoke() ?: key)
            val request = conversation.unfinished(action, episodeId, useCurrent)?.takeUnless { startNewChange }?.also {
                conversation.selectRecovery(it.requestId)
            } ?: conversation.structuredRequest(structured, label)
            conversation.persist(owner); checkAccount()
            before(request.requestId); checkAccount()
            val receipt = conversation.receipt ?: send(request.requestId).also { response ->
                checkAccount()
                conversation.confirmed(request, key, response)
            }
            structured.validate(receipt)
            conversation.persist(owner); checkAccount()
            if (conversation.wasRestored(request.requestId)) reconcileRecovered(receipt) else reconcile(receipt)
            checkAccount()
            conversation.complete(request, key, listOf("${receipt.action.wire}: ${receipt.spokenResponse}"), owner)
            checkAccount()
            return receipt
        } finally { conversation.release(lease) }
    }
}
