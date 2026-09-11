package com.henrydashwood.magpie.ui

import com.henrydashwood.magpie.data.RichArticleSample
import org.jsoup.Jsoup
import org.junit.Assert.*
import org.junit.Test

class ArticleDocumentTest {
    private val item = RichArticleSample.item

    @Test fun preservesReadingStructureAndMathWithoutChangingSpeech() {
        val document = Jsoup.parse(ArticleDocument.body(item))
        for (tag in listOf("h2", "strong", "em", "figure", "figcaption", "blockquote", "ol", "pre", "code", "table", "math", "mfrac", "munderover")) {
            assertTrue("Missing $tag", document.select(tag).isNotEmpty())
        }
        assertEquals("col", document.selectFirst("th")!!.attr("scope"))
        assertEquals("A magpie with a cream outline and a bright blue tail", document.selectFirst("img")!!.attr("alt"))
        assertTrue(document.selectFirst("pre")!!.wholeText().contains("\n    return"))
        assertTrue(document.selectFirst("math[display=block]")!!.parent()!!.hasClass("formula"))
        assertEquals(item.text, item.copy(html = "<p>A new display</p>").text)
    }

    @Test fun stripsActiveContentAndUnsafeImageAndLinkSources() {
        val html = """<script>alert(1)</script><style>body{display:none}</style><iframe src="https://evil.test"></iframe>
            <form><p>Hidden form text</p><input></form><svg onload="alert(1)"></svg>
            <p onclick="alert(1)" style="display:none">Still readable</p>
            <a href="javascript:alert(1)">Unsafe</a><a href="file:///secret">Local</a>
            <img src="file:///secret" onerror="alert(1)"><img src="content://secret">
            <img src="data:image/svg+xml;base64,AAAA"><img src="https://example.org/photo.png" alt="A tree">
            <math><semantics><mi>x</mi><annotation encoding="application/x-tex">raw latex</annotation></semantics></math>"""
        val document = Jsoup.parse(ArticleDocument.body(item.copy(html = html)))
        assertTrue(document.select("script, style, iframe, form, input, svg, annotation, [onclick], [onerror], [style]").isEmpty())
        assertFalse(document.text().contains("Hidden form text"))
        assertFalse(document.text().contains("raw latex"))
        assertEquals(0, document.select("a[href]").size)
        assertEquals(listOf("https://example.org/photo.png"), document.select("img[src]").map { it.attr("src") })
        assertTrue(document.text().contains("Still readable"))
        assertEquals("x", document.selectFirst("math")!!.text())
    }

    @Test fun resolvesRelativeImagesAndLinksAndPreservesCodeLiterally() {
        val document = Jsoup.parse(ArticleDocument.body(item.copy(originalUrl = "https://example.org/posts/story", html =
            """<a href="../about">About</a><img src="/image.png" alt="Picture"><pre><code>if (x &lt; 2) {
    println("${'$'}x")
}</code></pre>""")))
        assertEquals("https://example.org/about", document.selectFirst("a")!!.attr("href"))
        assertEquals("https://example.org/image.png", document.selectFirst("img")!!.attr("src"))
        assertEquals("if (x < 2) {\n    println(\"${'$'}x\")\n}", document.selectFirst("code")!!.wholeText())
    }

    @Test fun plainTextFallbackIsEscapedAndBlankHtmlDoesNotHideIt() {
        for (html in listOf(null, "", "<script>bad()</script>")) {
            val document = Jsoup.parse(ArticleDocument.body(item.copy(text = "A < B & C\nnext line\n\nLast paragraph", html = html)))
            assertEquals(2, document.select("p").size)
            assertEquals("A < B & C next line", document.selectFirst("p")!!.text())
            assertEquals(1, document.select("br").size)
        }
    }

    @Test fun footnotesKeepTheirTargetsInsideTheReader() {
        val document = Jsoup.parse(ArticleDocument.body(item.copy(originalUrl = "https://example.org/article", html =
            "<p><a href=\"#note-1\">Note</a></p><p id=\"note-1\">A footnote</p>")))
        assertEquals(ArticleDocument.LOCAL_BASE + "#note-1", document.selectFirst("a")!!.attr("href"))
        assertEquals("A footnote", document.getElementById("note-1")!!.text())
    }

    @Test fun pageEscapesMetadataAndOnlyAllowsItsOwnStyles() {
        val page = ArticleDocument.page(item.copy(title = "<script>bad()</script>", source = "A & B"), "<p>Body</p>",
            40f, "#FFFFFF", "#111318", "#CCCCCC", "#888888", "#A8C7FF", true)
        val document = Jsoup.parse(page)
        assertTrue(document.select("script").isEmpty())
        assertEquals("<script>bad()</script>", document.selectFirst("h1")!!.text())
        assertTrue(document.selectFirst("style")!!.data().contains("40.0px"))
        assertTrue(document.selectFirst("meta[http-equiv]")!!.attr("content").contains("default-src 'none'"))
        assertEquals(null, ArticleDocument.webUrl("javascript:alert(1)"))
        assertEquals(null, ArticleDocument.webUrl("https://user:password@example.org/"))
    }
}
