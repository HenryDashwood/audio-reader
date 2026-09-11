package com.henrydashwood.magpie

import android.app.Application
import com.henrydashwood.magpie.auth.*
import com.henrydashwood.magpie.data.*
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch

open class MagpieApplication : Application() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    open val accounts: AccountSession by lazy {
        AccountSession(HttpAccountApi(BuildConfig.ACCOUNT_API_URL), EncryptedAccountTokenStore(this, BuildConfig.ACCOUNT_API_URL),
            EncryptedApplePendingStore(EncryptedAccountTokenStore(this, BuildConfig.ACCOUNT_API_URL, "magpie-apple-pending")))
    }
    open val library: AccountLibrary by lazy {
        AccountLibrary(HttpLibraryApi(BuildConfig.ACCOUNT_API_URL, accounts::rejectToken), BuildConfig.ACCOUNT_API_URL, accounts.state.value.signedIn).also { repository ->
            scope.launch { accounts.accessToken.collectLatest { repository.changeSession(it) } }
        }
    }
}
