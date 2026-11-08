package com.henrydashwood.magpie;

import android.app.Activity;
import android.content.ComponentName;
import android.content.Intent;
import android.media.browse.MediaBrowser;
import android.os.Bundle;
import android.widget.TextView;

/** Runs under the test APK’s own UID, without access to the app’s Kotlin runtime. */
public class UntrustedMediaBrowserActivity extends Activity {
    private MediaBrowser browser;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        if (getIntent().getBooleanExtra("close", false)) {
            finish();
            return;
        }
        TextView status = new TextView(this);
        status.setText("Checking media-library access");
        status.setTextSize(24f);
        setContentView(status);
        ComponentName service = new ComponentName(getIntent().getStringExtra("target_package"),
                "com.henrydashwood.magpie.playback.PlaybackService");
        browser = new MediaBrowser(this, service, new MediaBrowser.ConnectionCallback() {
            @Override
            public void onConnected() {
                status.setText("Unexpected library access");
            }

            @Override
            public void onConnectionFailed() {
                status.setText("Magpie library access rejected");
            }
        }, null);
        browser.connect();
    }

    @Override
    protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        if (intent.getBooleanExtra("close", false)) finish();
    }

    @Override
    protected void onDestroy() {
        if (browser != null) browser.disconnect();
        super.onDestroy();
    }
}
