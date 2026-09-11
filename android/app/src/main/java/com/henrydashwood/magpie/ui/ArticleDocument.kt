package com.henrydashwood.magpie.ui

import com.henrydashwood.magpie.BuildConfig
import com.henrydashwood.magpie.data.LibraryItem
import org.jsoup.Jsoup
import org.jsoup.nodes.Document
import org.jsoup.nodes.Entities
import org.jsoup.safety.Cleaner
import org.jsoup.safety.Safelist
import java.net.URI
import java.util.UUID

/** Reading-only HTML. Speech and its UTF-16 bookmarks always use LibraryItem.text. */
object ArticleDocument {
    const val LOCAL_BASE = "https://${BuildConfig.APPLICATION_ID}/reader/"

    fun webUrl(value: String?): String? = value?.let {
        runCatching { URI(it) }.getOrNull()?.takeIf { uri ->
            uri.scheme?.lowercase() in setOf("https", "http") && !uri.host.isNullOrBlank() && uri.userInfo == null
        }?.toASCIIString()
    }

    /** Exact player paths only; no arbitrary pages, credentials, or publisher scripting options. */
    fun videoUrl(value: String): String? {
        val uri = runCatching { URI(if (value.startsWith("//")) "https:$value" else value) }.getOrNull() ?: return null
        if (uri.scheme !in setOf("https", "http") || uri.userInfo != null || uri.port !in setOf(-1, 80, 443)) return null
        val host = uri.host?.lowercase() ?: return null
        val query = uri.rawQuery.orEmpty().split("&").map { it.split("=", limit = 2) }
            .filter { it.size == 2 }.associate { it[0] to it[1] }
        if (host in setOf("youtube.com", "www.youtube.com", "youtube-nocookie.com", "www.youtube-nocookie.com") &&
            Regex("/embed/[A-Za-z0-9_-]{11}").matches(uri.rawPath.orEmpty())) {
            val times = listOf("start", "end").mapNotNull { key ->
                query[key]?.takeIf { Regex("[0-9]{1,8}").matches(it) }?.let { "&$key=$it" }
            }.joinToString("")
            return "https://www.youtube-nocookie.com${uri.rawPath}?playsinline=1$times"
        }
        if (host == "player.vimeo.com" && Regex("/video/[0-9]+").matches(uri.rawPath.orEmpty())) {
            val token = query["h"]?.takeIf { Regex("[A-Za-z0-9]+").matches(it) }?.let { "&h=$it" }.orEmpty()
            return "https://player.vimeo.com${uri.rawPath}?dnt=1$token"
        }
        return null
    }

    private fun videoPageUrl(embed: String): String {
        val uri = URI(embed)
        val id = uri.path.substringAfterLast('/')
        return if (uri.host == "www.youtube-nocookie.com") {
            val start = Regex("(?:^|&)start=([0-9]+)").find(uri.rawQuery.orEmpty())?.groupValues?.get(1)
            "https://www.youtube.com/watch?v=$id" + (start?.let { "&t=${it}s" } ?: "")
        } else {
            val token = Regex("(?:^|&)h=([A-Za-z0-9]+)").find(uri.rawQuery.orEmpty())?.groupValues?.get(1)
            "https://vimeo.com/$id" + (token?.let { "/$it" } ?: "")
        }
    }

    private fun safelist(): Safelist = Safelist.relaxed()
        .addTags("iframe", "figure", "figcaption", "hr", "del", "s", "mark", "wbr",
            "math", "merror", "mfrac", "mi", "mmultiscripts", "mn", "mo", "mover", "mpadded",
            "mphantom", "mprescripts", "mroot", "mrow", "ms", "mspace", "msqrt", "mstyle",
            "msub", "msubsup", "msup", "mtable", "mtd", "mtext", "mtr", "munder", "munderover", "none")
        .addAttributes("iframe", "src", "title")
        .addProtocols("iframe", "src", "https")
        .addAttributes(":all", "id", "lang", "dir")
        .addAttributes("span", "class")
        .addAttributes("th", "scope")
        .addAttributes("ol", "start", "reversed")
        .addAttributes("li", "value")
        .addAttributes("math", "display", "xmlns")
        .addAttributes("mfrac", "linethickness")
        .addAttributes("mi", "mathvariant")
        .addAttributes("mn", "mathvariant")
        .addAttributes("mo", "accent", "fence", "largeop", "lspace", "maxsize", "minsize", "movablelimits", "rspace", "separator", "stretchy", "symmetric")
        .addAttributes("mover", "accent")
        .addAttributes("mpadded", "depth", "height", "lspace", "voffset", "width")
        .addAttributes("ms", "lquote", "rquote")
        .addAttributes("mspace", "depth", "height", "width")
        .addAttributes("mstyle", "displaystyle", "mathvariant", "scriptlevel")
        .addAttributes("mtable", "columnalign", "columnspacing", "displaystyle", "frame", "rowalign", "rowspacing")
        .addAttributes("mtd", "columnalign", "columnspan", "rowalign", "rowspan")
        .addAttributes("mtr", "columnalign", "rowalign")
        .addAttributes("munder", "accentunder")
        .addAttributes("munderover", "accent", "accentunder")
        .removeProtocols("a", "href", "ftp", "mailto")
        .addProtocols("a", "href", "#")
        .removeProtocols("img", "src", "http")
        .addProtocols("img", "src", "data")

    fun body(item: LibraryItem): String {
        val source = item.html?.takeIf { it.isNotBlank() } ?: paragraphs(item.text)
        val parsed = Jsoup.parseBodyFragment(source, webUrl(item.originalUrl) ?: LOCAL_BASE)
        parsed.select("a[href]").filter { it.attr("href").startsWith("#") }.forEach {
            it.attr("href", LOCAL_BASE + it.attr("href"))
        }
        // Remove entire active/hidden subtrees, including their misleading fallback text.
        parsed.select("script, style, object, embed, form, input, button, textarea, select, video, audio, svg, annotation, annotation-xml").remove()
        parsed.select("iframe").forEach { frame ->
            val src = videoUrl(frame.attr("src"))
            if (src == null) frame.remove() else {
                val title = frame.attr("title").ifBlank { "Embedded video" }
                frame.empty().clearAttributes()
                frame.attr("src", src).attr("title", title)
            }
        }
        val document = Cleaner(safelist()).clean(parsed)
        document.outputSettings(Document.OutputSettings().prettyPrint(false))
        document.select("span[class]").forEach { span ->
            if (span.hasClass("formula")) span.attr("class", "formula") else span.removeAttr("class")
        }
        document.select("img").forEach { image ->
            val src = image.attr("src")
            val embedded = Regex("^data:image/(png|jpeg|gif|webp);base64,[A-Za-z0-9+/=\\r\\n]+$").matches(src)
            if (!embedded && webUrl(src)?.startsWith("https://") != true) image.removeAttr("src")
            image.attr("referrerpolicy", "no-referrer")
            if (!image.hasAttr("alt")) image.attr("alt", "Article image")
        }
        document.select("iframe").forEach { frame ->
            frame.attr("loading", "lazy")
                .attr("sandbox", "allow-scripts allow-same-origin allow-presentation")
                .attr("allow", "encrypted-media; picture-in-picture")
                .attr("referrerpolicy", "strict-origin-when-cross-origin")
            frame.after(org.jsoup.nodes.Element("p").attr("data-hearful-metadata", "")
                .appendChild(org.jsoup.nodes.Element("a").attr("href", videoPageUrl(frame.attr("src"))).text("Open video in browser")))
        }
        document.select("pre").attr("tabindex", "0")
        document.select("table").forEach { it.wrap("<div class=\"table-scroll\" tabindex=\"0\"></div>") }
        document.select("math[display=block]").forEach {
            if (it.parent()?.hasClass("formula") != true) it.wrap("<div class=\"formula\" tabindex=\"0\"></div>")
        }
        return document.body().html().takeIf { it.isNotBlank() } ?: paragraphs(item.text)
    }

    fun paragraphs(text: String): String = text.split(Regex("\\n\\s*\\n"))
        .filter { it.isNotBlank() }.joinToString("") { "<p>${escape(it).replace("\n", "<br>")}</p>" }

    private fun escape(value: String) = Entities.escape(value)

    fun page(item: LibraryItem, body: String, fontSize: Float, ink: String, background: String,
        quiet: String, rule: String, link: String, dark: Boolean): String {
        val nonce = UUID.randomUUID().toString()
        return """
            <!doctype html><html><head><meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <meta name="referrer" content="no-referrer">
            <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src https: data:; frame-src https://www.youtube-nocookie.com/embed/ https://player.vimeo.com/video/; style-src 'nonce-$nonce'; base-uri 'none'; form-action 'none'">
            <style nonce="$nonce">
            :root { color-scheme: ${if (dark) "dark" else "light"}; }
            * { box-sizing: border-box; }
            body { margin: 0; padding: 16px 20px 48px; background: $background; color: $ink;
              font: ${fontSize}px/1.55 system-ui, sans-serif; overflow-wrap: break-word; -webkit-text-size-adjust: none; }
            .page { overflow-x: clip; }
            h1 { font-size: 1.5em; line-height: 1.25; margin: 0 0 .2em; }
            h2, h3, h4, h5, h6 { line-height: 1.3; margin: 1.4em 0 .4em; }
            h2 { font-size: 1.25em; } h3, h4, h5, h6 { font-size: 1.1em; }
            p, ul, ol, dl, blockquote, pre, .table-scroll { margin: 0 0 1em; }
            .byline { color: $quiet; font-size: .9em; margin-bottom: 1.4em; }
            img { max-width: 100%; height: auto; display: block; margin: 1em auto; }
            iframe { display: block; width: 100%; aspect-ratio: 16 / 9; min-height: 200px; border: 0; margin: 1em 0; }
            figure { margin: 1em 0; } figcaption { color: $quiet; font-size: .88em; text-align: center; }
            blockquote { margin-left: 0; padding-left: 1em; border-left: 3px solid $rule; color: $quiet; }
            pre { overflow-x: auto; padding: .75em; border: 1px solid $rule; border-radius: 8px; font-size: .9em; white-space: pre; overflow-wrap: normal; }
            code { font-family: monospace; }
            .formula, .table-scroll { overflow-x: auto; max-width: 100%; }
            .formula { margin: 1.2em 0; padding-bottom: .25em; }
            .formula > math { width: max-content; margin: 0 auto; }
            table { border-collapse: collapse; } th, td { border: 1px solid $rule; padding: .4em .6em; text-align: start; }
            a { color: $link; } hr { border: 0; border-top: 1px solid $rule; margin: 2em 0; }
            </style></head><body><div class="page">
            <header><h1>${escape(item.title)}</h1><p class="byline">${escape(item.source)}</p></header>
            <main>$body</main></div></body></html>
        """.trimIndent()
    }
}
