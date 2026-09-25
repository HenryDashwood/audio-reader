package com.henrydashwood.magpie

import android.os.Bundle
import android.content.Intent
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import androidx.compose.runtime.mutableStateOf
import com.henrydashwood.magpie.shortcuts.MagpieShortcuts
import com.henrydashwood.magpie.shortcuts.ShortcutRequest
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.activity.enableEdgeToEdge
import androidx.lifecycle.viewmodel.compose.viewModel
import com.henrydashwood.magpie.ui.MagpieApp
import com.henrydashwood.magpie.ui.MagpieTheme

class MainActivity : ComponentActivity() {
    private var appleReturn by mutableIntStateOf(0)
    private var savedReturn by mutableIntStateOf(0)
    private var shortcut by mutableStateOf<ShortcutRequest?>(null)
    private fun handleReturn(intent: Intent?, acceptShortcut: Boolean = true) {
        if (acceptShortcut) MagpieShortcuts.take(this, intent)?.let {
            MagpieShortcuts.reportUsed(this, it)
            shortcut = it
        }
        if (intent?.getBooleanExtra("open_signin", false) == true) { appleReturn++; intent.removeExtra("open_signin") }
        if (intent?.getBooleanExtra("open_saved", false) == true) { savedReturn++; intent.removeExtra("open_saved") }
        // Signed out, the sign-in screen finishes an Apple return itself; opening Sign-in Methods
        // afterwards would be a detour.
        if (intent?.action == Intent.ACTION_VIEW && intent.data?.scheme == BuildConfig.APPLICATION_ID + ".auth" &&
            intent.data?.host == "apple-sign-in" && (application as MagpieApplication).let { !it.requiresSignIn || it.accounts.state.value.signedIn }) appleReturn++
    }
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleReturn(intent)
    }
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        runCatching { MagpieShortcuts.publish(this) }
        handleReturn(intent, acceptShortcut = savedInstanceState == null)
        val app = application as MagpieApplication
        setContent { MagpieTheme {
            val account by app.accounts.state.collectAsStateWithLifecycle()
            if (app.requiresSignIn && !account.signedIn) com.henrydashwood.magpie.auth.SignInScreen()
            else MagpieApp(viewModel(), appleReturn, savedReturn, shortcut) { shortcut = null }
        } }
    }
}
