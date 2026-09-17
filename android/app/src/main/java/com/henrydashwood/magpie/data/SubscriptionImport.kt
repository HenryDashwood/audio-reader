package com.henrydashwood.magpie.data

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import org.json.JSONObject
import java.util.UUID

data class ImportItem(val id: Int, val title: String, val host: String, val status: String,
    val message: String?, val selected: Boolean, val retryable: Boolean)
data class ImportJob(val id: String, val status: String, val duplicates: Int, val folders: Boolean,
    val total: Int, val finished: Int, val added: Int, val alreadyFollowing: Int,
    val failed: Int, val notImported: Int, val items: List<ImportItem>) {
    val active get() = status in setOf("queued", "running")
    val draft get() = status == "draft"
    val title get() = when { draft -> "Review subscriptions"; active -> "Importing subscriptions"
        status == "stopped" -> "Import stopped"; failed > 0 -> "Import finished with issues"; else -> "Import complete" }
    companion object {
        fun decode(json: JSONObject): ImportJob {
            val entries = json.getJSONArray("items")
            require(entries.length() <= 2000)
            return ImportJob(json.getString("id"), json.getString("status"), json.getInt("duplicates"), json.getBoolean("folders"),
                json.getInt("total"), json.getInt("finished"), json.getInt("added"), json.getInt("already_following"),
                json.getInt("failed"), json.getInt("not_imported"), (0 until entries.length()).map {
                    val row = entries.getJSONObject(it)
                    ImportItem(row.getInt("id"), row.getString("title"), row.getString("host"), row.getString("status"),
                        if (row.isNull("message")) null else row.getString("message"), row.getBoolean("selected"), row.getBoolean("retryable"))
                })
        }
    }
}

interface SubscriptionImportApi {
    suspend fun currentImport(token: String): ImportJob?
    suspend fun previewImport(token: String, bytes: ByteArray): ImportJob
    suspend fun mutateImport(token: String, id: String, action: String, requestId: String?, entries: Set<Int>?): ImportJob
}
interface SubscriptionImportRepository {
    val importSession: String?
    suspend fun currentImport(): ImportJob?
    suspend fun previewImport(bytes: ByteArray): ImportJob
    suspend fun mutateImport(id: String, action: String, requestId: String?, entries: Set<Int>?): ImportJob
}
data class ImportState(val showing: Boolean = false, val busy: Boolean = false, val job: ImportJob? = null,
    val selected: Set<Int> = emptySet(), val publicFeeds: Boolean = false, val error: String? = null, val uncertain: Boolean = false)

/** UI work is scoped to the initiating account/session; accepted work lives on the server. */
class SubscriptionImportController(private val scope: CoroutineScope, private val repository: SubscriptionImportRepository) {
    private val mutable = MutableStateFlow(ImportState())
    val state = mutable.asStateFlow()
    private var generation = 0
    private var work: Job? = null
    private var pendingStart: Triple<String, String, Set<Int>>? = null
    private var pendingRetry: Pair<String, String>? = null
    fun invalidate() { generation++; work?.cancel(); pendingStart = null; pendingRetry = null; mutable.value = ImportState() }
    fun open() { if (repository.importSession == null) return; mutable.value = mutable.value.copy(showing = true); refresh() }
    fun close() { mutable.value = mutable.value.copy(showing = false) }
    fun refresh() = perform { repository.currentImport() }
    fun preview(bytes: ByteArray) { if (pendingStart == null) perform { repository.previewImport(bytes) } }
    fun chooseAnother() { if (!state.value.busy && pendingStart == null) mutable.value = ImportState(showing = true) }
    fun fileError() { mutable.value = state.value.copy(error = "This file couldn't be opened. Choose an OPML file smaller than 5 MiB.") }
    fun select(id: Int, selected: Boolean) { if (state.value.busy || state.value.uncertain) return
        mutable.value = state.value.copy(selected = if (selected) state.value.selected + id else state.value.selected - id) }
    fun selectAll() { if (state.value.busy || state.value.uncertain) return
        mutable.value = state.value.copy(selected = if (state.value.selected.isEmpty()) state.value.job?.items.orEmpty()
            .filter { it.status == "ready" }.map { it.id }.toSet() else emptySet()) }
    fun publicFeeds(value: Boolean) { if (!state.value.busy && !state.value.uncertain) mutable.value = state.value.copy(publicFeeds = value) }
    fun start() {
        val state = state.value
        val job = state.job ?: return
        if (state.busy || !job.draft || !state.publicFeeds || state.selected.isEmpty()) return
        val pending = pendingStart ?: Triple(job.id, UUID.randomUUID().toString(), state.selected).also { pendingStart = it }
        mutable.value = state.copy(uncertain = true)
        perform { repository.mutateImport(pending.first, "start", pending.second, pending.third) }
    }
    fun stop() { val job = state.value.job ?: return; perform { repository.mutateImport(job.id, "stop", null, null) } }
    fun retry() {
        val job = state.value.job ?: return
        val pending = pendingRetry ?: (job.id to UUID.randomUUID().toString()).also { pendingRetry = it }
        perform { repository.mutateImport(pending.first, "retry", pending.second, null) }
    }
    private fun perform(action: suspend () -> ImportJob?) {
        if (state.value.busy) return
        val session = repository.importSession ?: return
        val ticket = generation
        mutable.value = state.value.copy(busy = true, error = null)
        work = scope.launch {
            try {
                val result = action()
                if (ticket != generation || session != repository.importSession) return@launch
                val changed = result?.id != state.value.job?.id
                if (result == null || changed || !result.draft) pendingStart = null
                if (changed) pendingRetry = null
                mutable.value = state.value.copy(job = result, busy = false,
                    selected = if (changed) result?.items.orEmpty().filter { it.status == "ready" }.map { it.id }.toSet() else state.value.selected,
                    publicFeeds = if (changed) false else state.value.publicFeeds, uncertain = pendingStart != null)
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (failure: Exception) {
                if (ticket == generation && session == repository.importSession)
                    mutable.value = state.value.copy(error = AccountLibrary.message(failure))
            } finally {
                if (ticket == generation && session == repository.importSession) mutable.value = state.value.copy(busy = false)
            }
        }
    }
}
