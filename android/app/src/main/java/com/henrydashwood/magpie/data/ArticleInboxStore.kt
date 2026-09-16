package com.henrydashwood.magpie.data

import android.annotation.SuppressLint
import android.content.Context
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject

/** App-private storage, excluded from backup with the rest of the preview data. */
class ArticleInboxStore(context: Context, name: String = "magpie_account_captures") : ArticleInbox, AccountIdentityStore {
    private val preferences = context.getSharedPreferences(name, Context.MODE_PRIVATE)
    private fun read(owner: String): List<PendingArticle> {
        val array = JSONArray(preferences.getString("inbox:$owner", "[]"))
        return (0 until array.length()).map { array.getJSONObject(it).let { row ->
            PendingArticle(row.getString("id"), row.getString("url"), row.getString("saved_at"),
                row.optString("title").takeIf { it.isNotEmpty() }, row.optString("html").takeIf { it.isNotEmpty() },
                row.optString("content_format", "page"), row.optBoolean("replace_existing"))
        } }
    }
    override suspend fun pending(owner: String) = withContext(Dispatchers.IO) { synchronized(lock) { read(owner) } }
    override suspend fun add(owner: String, article: PendingArticle) = withContext(Dispatchers.IO) { synchronized(lock) {
        val rows = read(owner)
        // Explicit captures keep their own IDs and order. Do not discard an earlier
        // offline HTML copy: a newer link-only capture might fail to prepare.
        // An in-flight acknowledgement can remove only the capture it uploaded.
        val old = rows.find { it.url == article.url }
        val next = when {
            old == null -> rows + article
            article.replaceExisting -> rows + article.copy(savedAt = old.savedAt)
            else -> rows
        }
        write(owner, next)
    } }
    override suspend fun remove(owner: String, id: String) = withContext(Dispatchers.IO) { synchronized(lock) { write(owner, read(owner).filterNot { it.id == id }) } }
    @SuppressLint("UseKtx")
    private fun write(owner: String, rows: List<PendingArticle>) {
        val array = JSONArray().apply { rows.forEach { put(JSONObject().put("id", it.id).put("url", it.url).put("saved_at", it.savedAt)
            .put("title", it.title).put("html", it.html).put("content_format", it.contentFormat).put("replace_existing", it.replaceExisting)) } }
        check(preferences.edit().putString("inbox:$owner", array.toString()).commit()) { "The link could not be saved on this device. Please try again." }
    }
    // The key is a server-bound token digest, never a credential. Remembering one
    // identity lets the same session queue links after an offline cold start.
    override fun owner(sessionKey: String): String? = synchronized(lock) {
        preferences.getString("owner", null).takeIf { preferences.getString("session", null) == sessionKey }
    }
    @SuppressLint("UseKtx")
    override suspend fun remember(sessionKey: String, owner: String) = withContext(Dispatchers.IO) { synchronized(lock) {
        check(preferences.edit().putString("session", sessionKey).putString("owner", owner).commit()) { "Could not remember this account on the device." }
    } }
    private companion object { val lock = Any() }
}
