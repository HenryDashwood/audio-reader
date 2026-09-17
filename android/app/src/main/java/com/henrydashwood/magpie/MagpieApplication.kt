package com.henrydashwood.magpie

import android.app.Application
import com.henrydashwood.magpie.auth.*
import com.henrydashwood.magpie.data.*
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch
import kotlinx.coroutines.isActive

open class MagpieApplication : Application() {
    private val visibility = com.henrydashwood.magpie.telemetry.ApplicationVisibility()
    val foregroundVisible get() = visibility.visible
    override fun onCreate() {
        super.onCreate()
        registerActivityLifecycleCallbacks(visibility)
    }
    open fun voiceInput(): com.henrydashwood.magpie.voice.VoiceInput = com.henrydashwood.magpie.voice.AndroidSpeechInput(this)
    open fun voiceOutput(selected: () -> String?): com.henrydashwood.magpie.voice.VoiceOutput = com.henrydashwood.magpie.voice.AndroidReplySpeaker(this, selected)
    private val mutableDiagnosticsEnabled by lazy { kotlinx.coroutines.flow.MutableStateFlow(PreviewStore(this).diagnosticsEnabled) }
    val diagnosticsEnabled get() = mutableDiagnosticsEnabled.asStateFlow()
    fun setDiagnosticsEnabled(enabled: Boolean) {
        PreviewStore(this).diagnosticsEnabled = enabled
        mutableDiagnosticsEnabled.value = enabled
        library.telemetry?.invalidate()
        if (!enabled) scope.launch { runCatching { library.telemetry?.clear() } }
    }
    open fun observeDiagnostics(repository: AccountLibrary, scope: CoroutineScope) {
        val queue = repository.telemetry ?: return
        val reporter = com.henrydashwood.magpie.telemetry.AndroidExitReporter(repository::telemetryScope,
            { repository.state.value.live && diagnosticsEnabled.value }, queue, com.henrydashwood.magpie.telemetry.FileExitMarkerStore(this),
            com.henrydashwood.magpie.telemetry.AndroidExitHistory(this))
        val mainThread = com.henrydashwood.magpie.telemetry.MainThreadDiagnostics(this, queue, repository::telemetryScope,
            scope, "${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE})", "Android ${android.os.Build.VERSION.RELEASE}", { foregroundVisible })
        mainThread.start()
        scope.launch {
            combine(repository.state.map { Triple(it.owner, it.revision, it.live) }.distinctUntilChanged(), diagnosticsEnabled) { account, enabled -> account to enabled }.collectLatest {
                mainThread.updateSession()
                try { reporter.update() }
                catch (cancelled: kotlinx.coroutines.CancellationException) { throw cancelled }
                catch (_: Exception) { /* Missing system diagnostics must never prevent playback. */ }
            }
        }
    }
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    fun progressWork(work: suspend () -> Unit) = scope.launch { work() }
    open fun createTelemetryStore(): com.henrydashwood.magpie.telemetry.TelemetryStore = com.henrydashwood.magpie.telemetry.FileTelemetryStore(this)
    open val articleInbox: ArticleInboxStore by lazy { ArticleInboxStore(this) }
    open val deviceLinkInbox: LinkInbox by lazy { LinkInbox(this) }
    open val accounts: AccountSession by lazy {
        AccountSession(HttpAccountApi(BuildConfig.ACCOUNT_API_URL), EncryptedAccountTokenStore(this, BuildConfig.ACCOUNT_API_URL),
            EncryptedApplePendingStore(EncryptedAccountTokenStore(this, BuildConfig.ACCOUNT_API_URL, "magpie-apple-pending")))
    }
    open val library: AccountLibrary by lazy {
        AccountLibrary(HttpLibraryApi(BuildConfig.ACCOUNT_API_URL, accounts::rejectToken), BuildConfig.ACCOUNT_API_URL, accounts.state.value.signedIn, articleInbox, FileLibraryCache(this),
            PodcastProgressQueue(FilePodcastProgressStore(this)), com.henrydashwood.magpie.voice.FileConversationStore(this), ArticleProgressQueue(FileArticleProgressStore(this)), createTelemetryStore(), { diagnosticsEnabled.value }).also { repository ->
            observeDiagnostics(repository, scope)
            scope.launch {
                while (kotlinx.coroutines.currentCoroutineContext().isActive) {
                    kotlinx.coroutines.delay(30_000)
                    try { repository.flushProgress(); repository.telemetry?.flush() }
                    catch (cancelled: kotlinx.coroutines.CancellationException) { throw cancelled }
                    catch (_: Exception) { /* Keep the journal for the next foreground/process retry. */ }
                }
            }
            scope.launch { com.henrydashwood.magpie.automation.AppFunctionAvailability.observe(this@MagpieApplication, repository) }
            scope.launch {
                var observedToken: String? = null
                combine(accounts.accessToken, accounts.state.map { it.libraryRevision }.distinctUntilChanged()) { token, revision -> token to revision }
                    .collectLatest { (token, revision) ->
                        if (observedToken != token) repository.state.value.owner?.let { PreviewStore(this@MagpieApplication).saveRestoration(it, null) }
                        observedToken = token
                        repository.changeSession(token)
                        if (token != null && revision > 0) repository.refresh()
                        if (token != null) try { repository.flushProgress(); repository.telemetry?.flush() }
                        catch (cancelled: kotlinx.coroutines.CancellationException) { throw cancelled }
                        catch (_: Exception) { /* The saved clock remains in the journal. */ }
                    }
            }
        }
    }
}
