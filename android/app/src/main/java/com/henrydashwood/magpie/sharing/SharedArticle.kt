package com.henrydashwood.magpie.sharing

import android.content.Intent
import com.henrydashwood.magpie.data.PendingArticle
import com.henrydashwood.magpie.data.validateLink
import org.jsoup.Jsoup

/** Untrusted input is previewed as plain text, never loaded as an executable page. */
data class SharedArticle(val url: String, val title: String? = null, val html: String? = null,
    val contentFormat: String = "page", val preview: String? = null) {
    fun pending() = PendingArticle(url = validateLink(url), title = title, html = html,
        contentFormat = contentFormat, replaceExisting = true)
}

object SharedArticles {
    const val MAX_BYTES = 2_000_000
    fun parse(text: String?, title: String? = null, html: String? = null): SharedArticle {
        require((text?.length ?: 0) <= MAX_BYTES && (html?.toByteArray(Charsets.UTF_8)?.size ?: 0) <= MAX_BYTES) {
            "This page is too large to capture. Share its link instead."
        }
        val raw = text?.trim().orEmpty()
        val exact = runCatching { validateLink(raw) }.getOrNull()
        val urls = if (exact != null) listOf(exact) else Regex("https?://[^\\s<>\"']+", RegexOption.IGNORE_CASE)
            .findAll(raw).map { match ->
                var url = match.value.trimEnd('.', ',', ';', '!', '?', ']')
                while (url.endsWith(')') && url.count { it == ')' } > url.count { it == '(' }) url = url.dropLast(1)
                runCatching { validateLink(url) }.getOrNull()
            }.filterNotNull().distinct().toList()
        require(urls.size == 1) { if (urls.size > 1) "Share one web link at a time." else "Share an http:// or https:// web link to save an article." }
        val body = html?.takeIf { it.isNotBlank() }
        val preview = body?.let {
            Jsoup.parse(it).apply { select("script, style, form, input, textarea, button, nav, footer").remove() }.body().text().take(600)
        }?.takeIf { it.isNotBlank() }
        return SharedArticle(urls.single(), title?.trim()?.take(500)?.takeIf { it.isNotBlank() }, body, preview = preview)
    }
    fun fromIntent(intent: Intent): SharedArticle {
        require(intent.action == Intent.ACTION_SEND && intent.type in listOf("text/plain", "text/html")) { "Share a web link or article to Magpie." }
        // Deliberately never dereference content/file URIs or arbitrary parcelables.
        val text = intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()
            ?: intent.clipData?.takeIf { it.itemCount == 1 }?.getItemAt(0)?.let { it.text?.toString() ?: it.uri?.toString() }
        val title = intent.getStringExtra(Intent.EXTRA_SUBJECT) ?: intent.getStringExtra(Intent.EXTRA_TITLE)
        val html = intent.getStringExtra(Intent.EXTRA_HTML_TEXT)
        return parse(text, title, html)
    }
}
