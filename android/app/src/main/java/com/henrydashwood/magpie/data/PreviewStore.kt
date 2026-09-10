package com.henrydashwood.magpie.data

import android.content.Context
import android.annotation.SuppressLint
import androidx.core.content.edit
import com.henrydashwood.magpie.playback.ArticleBookmark

val playbackRates = listOf(0.75f, 1f, 1.25f, 1.5f, 1.75f, 2f)

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
    var saved: Set<String>
        get() = preferences.getStringSet("saved", setOf("walking"))!!.toSet()
        set(value) { preferences.edit { putStringSet("saved", value) } }
    var finished: Set<String>
        get() = preferences.getStringSet("finished", emptySet())!!.toSet()
        set(value) { preferences.edit { putStringSet("finished", value) } }
    // Fall back to the original shared speed so existing preview installs retain their preference.
    fun speed(kind: ContentKind): Float = preferences.getFloat("speed:${kind.name}", preferences.getFloat("speed", 1f)).coerceIn(0.75f, 2f)
    fun saveSpeed(kind: ContentKind, value: Float) { preferences.edit { putFloat("speed:${kind.name}", value.coerceIn(0.75f, 2f)) } }
    var voiceId: String?
        get() = preferences.getString("voice", null)
        set(value) { preferences.edit { putString("voice", value) } }
    var lastItem: String?
        get() = preferences.getString("last_item", null)
        set(value) { preferences.edit { putString("last_item", value) } }
    fun position(id: String): Long = preferences.getLong("position:$id", 0)
    fun savePosition(id: String, position: Long) {
        preferences.edit { putLong("position:$id", position) }
    }
    fun bookmark(id: String): ArticleBookmark? = preferences.getString("version:$id", null)?.let {
        ArticleBookmark(it, preferences.getInt("offset:$id", 0))
    }
    fun saveBookmark(id: String, bookmark: ArticleBookmark) {
        preferences.edit {
            putString("version:$id", bookmark.contentVersion)
            putInt("offset:$id", bookmark.offsetUtf16)
        }
    }
}
