package com.henrydashwood.magpie

import android.app.Activity
import android.content.ComponentName
import android.content.Intent
import android.media.browse.MediaBrowser
import android.os.Bundle
import android.widget.TextView

/** Native-only companion: it has its own UID and no media-control or notification access. */
class UntrustedMediaBrowserActivity : Activity() {
    private var browser: MediaBrowser? = null
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (intent.getBooleanExtra("close", false)) { finish(); return }
        val status = TextView(this).apply { text = "Checking media-library access"; textSize = 24f }
        setContentView(status)
        browser = MediaBrowser(this, ComponentName(checkNotNull(intent.getStringExtra("target_package")),
            "com.henrydashwood.magpie.playback.PlaybackService"), object : MediaBrowser.ConnectionCallback() {
            override fun onConnected() { status.text = "Unexpected library access" }
            override fun onConnectionFailed() { status.text = "Magpie library access rejected" }
        }, null).also { it.connect() }
    }
    override fun onNewIntent(intent: Intent) { super.onNewIntent(intent); if (intent.getBooleanExtra("close", false)) finish() }
    override fun onDestroy() { browser?.disconnect(); super.onDestroy() }
}
