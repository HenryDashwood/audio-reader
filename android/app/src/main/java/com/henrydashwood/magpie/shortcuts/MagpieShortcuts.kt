package com.henrydashwood.magpie.shortcuts

import android.content.Context
import android.content.Intent
import android.content.pm.ShortcutInfo
import android.content.pm.ShortcutManager
import android.graphics.drawable.Icon
import com.henrydashwood.magpie.MainActivity
import com.henrydashwood.magpie.R
import java.security.MessageDigest
import java.util.UUID

enum class ShortcutAction(val label: String) {
    Ask("Ask Magpie"), Continue("Continue listening"), Latest("Play latest"), Saved("Saved articles"),
    Following("Following"), Player("Now playing"), Shortcuts("Shortcuts"), ReadItem("Open item"),
    PlayItem("Play item"), PlayFeed("Play a show's latest"),
}
data class ShortcutRequest(val action: ShortcutAction, val owner: String? = null,
    val itemId: String? = null, val feedId: String? = null, val delivery: String = UUID.randomUUID().toString())

/** Only navigational/playback actions. External intents cannot submit AI requests or start recording. */
object MagpieShortcuts {
    private const val ACTION = "com.henrydashwood.magpie.SHORTCUT"
    private const val CHOICE = "shortcut_action"
    private const val OWNER = "shortcut_owner"
    private const val ITEM = "shortcut_item"
    private const val FEED = "shortcut_feed"
    val basics = listOf(ShortcutAction.Ask, ShortcutAction.Continue, ShortcutAction.Latest, ShortcutAction.Saved)
    fun intent(context: Context, request: ShortcutRequest) = Intent(context, MainActivity::class.java).apply {
        action = ACTION
        flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
        putExtra(CHOICE, request.action.name); putExtra(OWNER, request.owner)
        putExtra(ITEM, request.itemId); putExtra(FEED, request.feedId)
    }
    fun take(intent: Intent?): ShortcutRequest? {
        if (intent?.action != ACTION) return null
        val result = runCatching {
            val action = ShortcutAction.entries.firstOrNull { it.name == intent.getStringExtra(CHOICE) } ?: return@runCatching null
            val owner = intent.getStringExtra(OWNER)
            val item = intent.getStringExtra(ITEM)
            val feed = intent.getStringExtra(FEED)
            if (owner != null && owner != "sample" && !owner.matches(Regex("[a-f0-9]{64}"))) return@runCatching null
            if (item != null && (item.isBlank() || item.length > 160)) return@runCatching null
            if (feed != null && (feed.isBlank() || feed.length > 256)) return@runCatching null
            if (action in setOf(ShortcutAction.ReadItem, ShortcutAction.PlayItem) && (owner == null || item == null)) return@runCatching null
            if (action == ShortcutAction.PlayFeed && (owner == null || feed == null)) return@runCatching null
            ShortcutRequest(action, owner, item, feed)
        }.getOrNull()
        // A recreation or task relaunch must never repeat an already-delivered Play.
        intent.action = Intent.ACTION_MAIN
        listOf(CHOICE, OWNER, ITEM, FEED).forEach(intent::removeExtra)
        return result
    }
    fun icon(action: ShortcutAction) = when (action) {
        ShortcutAction.Ask -> R.drawable.ic_shortcut_mic
        ShortcutAction.Saved -> R.drawable.ic_shortcut_bookmark
        ShortcutAction.ReadItem, ShortcutAction.Following, ShortcutAction.Shortcuts -> R.drawable.ic_shortcut_article
        else -> R.drawable.ic_shortcut_play
    }
    private fun info(context: Context, request: ShortcutRequest, label: String): ShortcutInfo {
        val id = if (request.owner == null) "magpie-${request.action.name.lowercase()}" else {
            val key = "${request.owner}:${request.action}:${request.itemId}:${request.feedId}"
            "magpie-target-" + MessageDigest.getInstance("SHA-256").digest(key.toByteArray()).joinToString("") { "%02x".format(it) }
        }
        return ShortcutInfo.Builder(context, id).setShortLabel(label.take(40)).setLongLabel(label.take(100))
            .setIcon(Icon.createWithResource(context, icon(request.action))).setIntent(intent(context, request)).build()
    }
    fun publish(context: Context) {
        val manager = context.getSystemService(ShortcutManager::class.java) ?: return
        if (manager.isRateLimitingActive) return
        manager.dynamicShortcuts = basics.take(manager.maxShortcutCountPerActivity).map { info(context, ShortcutRequest(it), it.label) }
    }
    fun pin(context: Context, request: ShortcutRequest, label: String = request.action.label): Boolean {
        val manager = context.getSystemService(ShortcutManager::class.java) ?: return false
        return manager.isRequestPinShortcutSupported && manager.requestPinShortcut(info(context, request, label), null)
    }
    fun supportsPin(context: Context) = context.getSystemService(ShortcutManager::class.java)?.isRequestPinShortcutSupported == true
}
