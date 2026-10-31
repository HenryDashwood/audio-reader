package com.henrydashwood.magpie.sharing

import android.app.Application
import android.content.Intent
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.henrydashwood.magpie.MagpieApplication
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

data class ShareState(val article: SharedArticle? = null, val error: String? = null,
    val busy: Boolean = false, val saved: Boolean = false, val browser: Boolean = false,
    val accountChanged: Boolean = false, val preparing: Boolean = false, val saveRequested: Boolean = false)

class ShareModel(application: Application) : AndroidViewModel(application) {
    private val app = application as MagpieApplication
    val library = app.library.state
    private val mutable = MutableStateFlow(ShareState())
    val state = mutable.asStateFlow()
    private var started = false
    private var generation = 0
    private var revision = library.value.revision
    private var work: Job? = null
    private var preparation: Job? = null
    init {
        viewModelScope.launch {
            library.collect { snapshot ->
                if (revision != snapshot.revision) {
                    revision = snapshot.revision
                    // Initial sign-in restoration may arrive before any input is ready.
                    if (mutable.value.article != null && !mutable.value.saved) {
                        generation++; work?.cancel(); preparation?.cancel()
                        mutable.value = mutable.value.copy(busy = false, browser = false, preparing = false, saveRequested = false, accountChanged = true,
                            error = "Your account changed. Review this article again before saving.")
                    }
                }
            }
        }
    }
    /** [capture]: opened from Saved's "Capture page", so go straight to the in-app page. */
    fun receive(intent: Intent, saved: Boolean = false, fresh: Boolean = false, capture: Boolean = false) {
        if (started && !fresh) return
        started = true; generation++; work?.cancel(); preparation?.cancel()
        if (saved) { mutable.value = ShareState(saved = true); return }
        mutable.value = ShareState(busy = true)
        val version = generation
        work = viewModelScope.launch {
            try {
                var article = withContext(Dispatchers.Default) { SharedArticles.fromIntent(intent) }
                val token = app.accounts.accessToken.value
                if (article.html == null && article.contentFormat != "pdf" && token != null) {
                    try {
                        val pdfClient = com.henrydashwood.magpie.data.PDFClient(com.henrydashwood.magpie.BuildConfig.ACCOUNT_API_URL, token)
                        if (pdfClient.resolve(article.url)) article = article.copy(contentFormat = "pdf", preview = null)
                    } catch (cancelled: CancellationException) { throw cancelled }
                    catch (_: Exception) { /* The ordinary webpage flow remains available. */ }
                }
                if (version != generation) return@launch
                val https = captureWebUrl(article.url)
                // Chrome and most Android browsers share only a link. Without page HTML from the
                // sender, read the page here so one Save captures it as Safari's share does.
                val prepare = !capture && https && article.html == null && article.contentFormat != "pdf"
                mutable.value = ShareState(article, browser = capture && https, preparing = prepare)
                if (prepare) preparation = viewModelScope.launch {
                    delay(PREPARATION_MILLIS)
                    if (version == generation) prepared(null)
                }
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (failure: Exception) { if (version == generation) mutable.value = ShareState(error = failure.message ?: "This share could not be opened.") }
        }
    }
    /** Hidden capture returns rendered text, a website sign-in requirement, or null for a link. */
    fun prepared(article: SharedArticle?) {
        val current = state.value
        if (!current.preparing) return
        preparation?.cancel()
        mutable.value = current.copy(preparing = false, saveRequested = false,
            article = article?.copy(title = article.title ?: current.article?.title)
                ?: current.article?.copy(captureIssue = CaptureIssue.UNAVAILABLE))
        if (current.saveRequested && state.value.article?.captureIssue == null) save()
    }
    fun reviewAccount() { mutable.value = state.value.copy(accountChanged = false, error = null) }
    fun openBrowser() {
        val current = state.value
        if (current.busy || current.saved || current.accountChanged || current.article?.url?.let(::captureWebUrl) != true) return
        preparation?.cancel()
        mutable.value = current.copy(browser = true, preparing = false, saveRequested = false, error = null)
    }
    fun closeBrowser() { mutable.value = state.value.copy(browser = false) }
    fun captured(article: SharedArticle) {
        if (state.value.browser && !state.value.accountChanged) mutable.value = state.value.copy(article = article, browser = false, error = null)
    }
    fun saveLink() {
        val before = state.value
        if (before.busy || before.preparing || before.saved || before.accountChanged) return
        mutable.value = before.copy(article = before.article?.copy(html = null, preview = null, captureIssue = null))
        save()
    }
    fun save() {
        val before = state.value
        val article = before.article ?: return
        if (before.busy || before.saved || before.accountChanged) return
        // Save waits for the page being read rather than storing a bare link.
        if (before.preparing) { mutable.value = before.copy(saveRequested = true, error = null); return }
        if (article.captureIssue != null) { openBrowser(); return }
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

private const val PREPARATION_MILLIS = 20_000L
