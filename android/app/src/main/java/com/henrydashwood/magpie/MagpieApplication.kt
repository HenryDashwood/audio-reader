package com.henrydashwood.magpie

import android.app.Application
import com.henrydashwood.magpie.auth.*
import com.henrydashwood.magpie.data.*
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch

open class MagpieApplication : Application() {
    open fun voiceInput(): com.henrydashwood.magpie.voice.VoiceInput = com.henrydashwood.magpie.voice.AndroidSpeechInput(this)
    open fun voiceOutput(selected: () -> String?): com.henrydashwood.magpie.voice.VoiceOutput = com.henrydashwood.magpie.voice.AndroidReplySpeaker(this, selected)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    open val articleInbox: ArticleInboxStore by lazy { ArticleInboxStore(this) }
    open val deviceLinkInbox: LinkInbox by lazy { LinkInbox(this) }
    open val accounts: AccountSession by lazy {
        AccountSession(HttpAccountApi(BuildConfig.ACCOUNT_API_URL), EncryptedAccountTokenStore(this, BuildConfig.ACCOUNT_API_URL),
            EncryptedApplePendingStore(EncryptedAccountTokenStore(this, BuildConfig.ACCOUNT_API_URL, "magpie-apple-pending")))
    }
    open val library: AccountLibrary by lazy {
        AccountLibrary(HttpLibraryApi(BuildConfig.ACCOUNT_API_URL, accounts::rejectToken), BuildConfig.ACCOUNT_API_URL, accounts.state.value.signedIn, articleInbox).also { repository ->
            scope.launch {
                combine(accounts.accessToken, accounts.state.map { it.libraryRevision }.distinctUntilChanged()) { token, revision -> token to revision }
                    .collectLatest { (token, revision) ->
                        repository.changeSession(token)
                        if (token != null && revision > 0) repository.refresh()
                    }
            }
        }
    }
}
