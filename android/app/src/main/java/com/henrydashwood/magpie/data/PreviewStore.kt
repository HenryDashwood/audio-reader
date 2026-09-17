package com.henrydashwood.magpie.data

import android.content.Context
import android.annotation.SuppressLint
import androidx.core.content.edit
import com.henrydashwood.magpie.playback.ArticleBookmark

val playbackRates = listOf(0.5f, 0.75f, 1f, 1.25f, 1.5f, 1.75f, 2f, 2.5f, 3f)

/** Local preview state only. This is deliberately not the backend's position_seconds contract. */
class PreviewStore(context: Context) {
    private val preferences = context.getSharedPreferences("magpie_preview", Context.MODE_PRIVATE)
    val dismissedFromLatest: Set<String>
        get() = preferences.getStringSet("latest_dismissed", emptySet()).orEmpty().toSet()

    // Clear is acknowledged only after the disk write. KTX edit(commit = true)
    // discards that result; the model calls this operation on Dispatchers.IO.
    @SuppressLint("UseKtx")
    fun dismissFromLatest(ids: Set<String>): Set<String> {
        val dismissed = dismissedFromLatest + ids
        check(preferences.edit().putStringSet("latest_dismissed", dismissed).commit()) { "Latest could not be cleared on this device. Please try again." }
        return dismissed
    }
    @SuppressLint("UseKtx")
    fun fileSample(id: String, action: ItemFilingAction) {
        val edit = preferences.edit()
        when (action) {
            ItemFilingAction.Finish -> edit.putStringSet("finished", finished + id)
            ItemFilingAction.Dismiss -> edit.putStringSet("latest_dismissed", dismissedFromLatest + id)
            ItemFilingAction.Restore -> edit.putStringSet("finished", finished - id)
                .putStringSet("latest_dismissed", dismissedFromLatest - id)
        }
        if (action != ItemFilingAction.Dismiss) edit.remove("version:$id").remove("offset:$id").putLong("position:$id", 0)
        check(edit.commit()) { "The change could not be saved on this device. Please try again." }
    }
    var saved: Set<String>
        get() = preferences.getStringSet("saved", setOf("walking"))!!.toSet()
        set(value) { preferences.edit { putStringSet("saved", value) } }
    var finished: Set<String>
        get() = preferences.getStringSet("finished", emptySet())!!.toSet()
        set(value) { preferences.edit { putStringSet("finished", value) } }
    // Fall back to the original shared speed so existing preview installs retain their preference.
    fun speed(kind: ContentKind): Float = preferences.getFloat("speed:${kind.name}", preferences.getFloat("speed", 1f)).takeIf { it.isFinite() }?.coerceIn(0.5f, 3f) ?: 1f
    fun saveSpeed(kind: ContentKind, value: Float) { require(value.isFinite()); preferences.edit { putFloat("speed:${kind.name}", value.coerceIn(0.5f, 3f)) } }
    var conversation: com.henrydashwood.magpie.voice.ConversationPreferences
        get() = com.henrydashwood.magpie.voice.ConversationPreferences(
            preferences.getBoolean("conversation_keep_listening", true),
            preferences.getInt("conversation_wait", 15).takeIf { it in com.henrydashwood.magpie.voice.ConversationPreferences.waitOptions } ?: 15)
        set(value) { preferences.edit { putBoolean("conversation_keep_listening", value.keepListening); putInt("conversation_wait", value.followUpSeconds) } }
    var diagnosticsEnabled: Boolean
        get() = preferences.getBoolean("diagnostics_enabled", true)
        set(value) { preferences.edit { putBoolean("diagnostics_enabled", value) } }
    var voiceId: String?
        get() = preferences.getString("voice", null)
        set(value) { preferences.edit { putString("voice", value) } }
    var lastItem: String?
        get() = preferences.getString("last_item", null)
        set(value) { preferences.edit { putString("last_item", value) } }
    // Explicit Continue is independent of whether the mini player was dismissed.
    fun continuation(owner: String?) = preferences.getString("continue:${owner ?: "sample"}", null)
    fun saveContinuation(owner: String?, id: String?) { preferences.edit { putString("continue:${owner ?: "sample"}", id) } }
    fun position(id: String): Long = preferences.getLong("position:$id", 0)
    fun savePosition(id: String, position: Long) {
        preferences.edit { putLong("position:$id", position) }
    }
    fun bookmark(id: String): ArticleBookmark? = preferences.getString("version:$id", null)?.let {
        ArticleBookmark(it, preferences.getInt("offset:$id", 0))
    }
    fun clearBookmark(id: String) { preferences.edit { remove("version:$id"); remove("offset:$id") } }
    fun saveBookmark(id: String, bookmark: ArticleBookmark) {
        preferences.edit {
            putString("version:$id", bookmark.contentVersion)
            putInt("offset:$id", bookmark.offsetUtf16)
        }
    }
}
