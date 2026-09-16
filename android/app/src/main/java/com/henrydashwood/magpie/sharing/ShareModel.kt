package com.henrydashwood.magpie.sharing

import android.app.Application
import android.content.Intent
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.henrydashwood.magpie.MagpieApplication
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

data class ShareState(val article: SharedArticle? = null, val error: String? = null,
    val busy: Boolean = false, val saved: Boolean = false, val browser: Boolean = false,
    val accountChanged: Boolean = false)

class ShareModel(application: Application) : AndroidViewModel(application) {
    private val app = application as MagpieApplication
    val library = app.library.state
    private val mutable = MutableStateFlow(ShareState())
    val state = mutable.asStateFlow()
    private var started = false
    private var generation = 0
    private var revision = library.value.revision
    private var work: Job? = null
    init {
        viewModelScope.launch {
            library.collect { snapshot ->
                if (revision != snapshot.revision) {
                    revision = snapshot.revision
                    // Initial sign-in restoration may arrive before any input is ready.
                    if (mutable.value.article != null && !mutable.value.saved) {
                        generation++; work?.cancel()
                        mutable.value = mutable.value.copy(busy = false, browser = false, accountChanged = true,
                            error = "Your account changed. Review this article again before saving.")
                    }
                }
            }
        }
    }
    fun receive(intent: Intent, saved: Boolean = false, fresh: Boolean = false) {
        if (started && !fresh) return
        started = true; generation++; work?.cancel()
        if (saved) { mutable.value = ShareState(saved = true); return }
        mutable.value = ShareState(busy = true)
        val version = generation
        work = viewModelScope.launch {
            try {
                val article = withContext(Dispatchers.Default) { SharedArticles.fromIntent(intent) }
                if (version == generation) mutable.value = ShareState(article)
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (failure: Exception) { if (version == generation) mutable.value = ShareState(error = failure.message ?: "This share could not be opened.") }
        }
    }
    fun reviewAccount() { mutable.value = state.value.copy(accountChanged = false, error = null) }
    fun openBrowser() { if (!state.value.busy && !state.value.accountChanged) mutable.value = state.value.copy(browser = true, error = null) }
    fun closeBrowser() { mutable.value = state.value.copy(browser = false) }
    fun captured(article: SharedArticle) {
        if (state.value.browser && !state.value.accountChanged) mutable.value = state.value.copy(article = article, browser = false, error = null)
    }
    fun save() {
        val before = state.value
        val article = before.article ?: return
        if (before.busy || before.saved || before.accountChanged) return
        val snapshot = library.value
        val owner = snapshot.owner
        if (!snapshot.live || owner == null) {
            mutable.value = before.copy(error = "Open Magpie and sign in before saving this article."); return
        }
        val version = generation
        mutable.value = before.copy(busy = true, error = null)
        work = viewModelScope.launch {
            try {
                // Confirmation binds this durable write to exactly this account. The app
                // prepares it when opened; closing a share never loses an accepted capture.
                app.articleInbox.add(owner, article.pending())
                if (version != generation || snapshot.revision != library.value.revision) return@launch
                mutable.value = before.copy(busy = false, saved = true)
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (failure: Exception) { if (version == generation) mutable.value = before.copy(error = failure.message ?: "Could not save on this device. Try again.") }
        }
    }
}
