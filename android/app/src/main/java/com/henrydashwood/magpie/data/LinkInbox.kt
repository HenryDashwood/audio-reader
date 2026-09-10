package com.henrydashwood.magpie.data

import android.content.Context
import android.annotation.SuppressLint
import java.net.URI

/** Durable local URL captures, kept separate from the disposable sample catalogue. */
class LinkInbox(context: Context, preferenceName: String = "magpie_link_inbox") {
    private val preferences = context.getSharedPreferences(preferenceName, Context.MODE_PRIVATE)
    fun links(): List<String> = synchronized(lock) { preferences.getStringSet("urls", emptySet()).orEmpty().sorted() }

    fun add(raw: String): Boolean = synchronized(lock) {
        val url = validateLink(raw)
        val next = links().toMutableSet()
        val added = next.add(url)
        check(persist(next)) { "The link could not be saved on this device. Please try again." }
        added
    }

    fun remove(url: String) = synchronized(lock) {
        check(persist(links().toSet() - url)) { "The link could not be removed. Please try again." }
    }

    // KTX edit(commit = true) discards the result. Capture must confirm the disk write
    // before reporting success; callers run mutations on Dispatchers.IO. Even a
    // duplicate retries the write, because a failed commit can update the memory cache.
    @SuppressLint("UseKtx")
    private fun persist(urls: Set<String>): Boolean = preferences.edit().putStringSet("urls", urls).commit()

    private companion object { val lock = Any() }
}

fun validateLink(raw: String): String {
    val value = raw.trim()
    val uri = runCatching { URI(value) }.getOrNull()
    require(value.isNotEmpty() && value.length <= 8192 && uri != null &&
        (uri.scheme.equals("https", true) || uri.scheme.equals("http", true)) &&
        !uri.host.isNullOrBlank() && uri.rawUserInfo == null && uri.port in -1..65535) {
        "Enter a valid http:// or https:// web address."
    }
    return value
}
