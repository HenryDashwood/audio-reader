package com.henrydashwood.magpie

import android.app.Application
import android.content.Context
import androidx.test.runner.AndroidJUnitRunner
import com.henrydashwood.magpie.auth.*

/** UI tests use an isolated signed-out session, never the owner's live account. */
class MagpieTestApplication : MagpieApplication() {
    override val articleInbox by lazy { com.henrydashwood.magpie.data.ArticleInboxStore(this, "magpie_test_account_captures") }
    override val deviceLinkInbox by lazy { com.henrydashwood.magpie.data.LinkInbox(this, "magpie_test_device_links") }
    var libraryOverride: com.henrydashwood.magpie.data.AccountLibrary? = null
    override val library get() = libraryOverride ?: super.library
    override val accounts by lazy {
        AccountSession(HttpAccountApi("https://unused.invalid"), object : AccountTokenStore {
            private var token: String? = null
            override fun read() = token
            override fun write(token: String) { this.token = token }
            override fun clear() { token = null }
        })
    }
}
class MagpieTestRunner : AndroidJUnitRunner() {
    override fun newApplication(cl: ClassLoader, className: String, context: Context): Application =
        super.newApplication(cl, MagpieTestApplication::class.java.name, context)
}
