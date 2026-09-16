package com.henrydashwood.magpie.shortcuts

import android.app.PendingIntent
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService

abstract class MagpieTile : TileService() {
    abstract val action: ShortcutAction
    override fun onStartListening() {
        super.onStartListening()
        qsTile?.apply { state = Tile.STATE_INACTIVE; label = action.label; contentDescription = action.label; updateTile() }
    }
    // The legacy overload is reachable only below API 34, where the replacement does not exist.
    @android.annotation.SuppressLint("StartActivityAndCollapseDeprecated")
    override fun onClick() {
        super.onClick()
        // Library titles and account actions stay behind the device lock screen.
        unlockAndRun {
            val intent = MagpieShortcuts.trustedIntent(this, ShortcutRequest(action))
            if (Build.VERSION.SDK_INT >= 34) {
                startActivityAndCollapse(PendingIntent.getActivity(this, action.ordinal, intent,
                    PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT))
            } else {
                // The PendingIntent overload was added in API 34; keep API 31–33 support.
                @Suppress("DEPRECATION")
                startActivityAndCollapse(intent)
            }
        }
    }
}
class AskMagpieTile : MagpieTile() { override val action = ShortcutAction.Ask }
class ContinueListeningTile : MagpieTile() { override val action = ShortcutAction.Continue }
