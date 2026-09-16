package com.henrydashwood.magpie

import android.os.Bundle
import android.content.Intent
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.lifecycle.viewmodel.compose.viewModel
import com.henrydashwood.magpie.ui.MagpieApp
import com.henrydashwood.magpie.ui.MagpieTheme

class MainActivity : ComponentActivity() {
    private var appleReturn by mutableIntStateOf(0)
    private var savedReturn by mutableIntStateOf(0)
    private fun handleReturn(intent: Intent?) {
        if (intent?.getBooleanExtra("open_signin", false) == true) { appleReturn++; intent.removeExtra("open_signin") }
        if (intent?.getBooleanExtra("open_saved", false) == true) { savedReturn++; intent.removeExtra("open_saved") }
        if (intent?.action == Intent.ACTION_VIEW && intent.data?.scheme == BuildConfig.APPLICATION_ID + ".auth" &&
            intent.data?.host == "apple-sign-in") appleReturn++
    }
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleReturn(intent)
    }
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        handleReturn(intent)
        setContent { MagpieTheme { MagpieApp(viewModel(), appleReturn, savedReturn) } }
    }
}
