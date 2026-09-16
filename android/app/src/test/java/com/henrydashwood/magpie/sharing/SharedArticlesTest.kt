package com.henrydashwood.magpie.sharing

import org.junit.Assert.*
import org.junit.Test

class SharedArticlesTest {
    @Test fun acceptsExactLinksAndExtractsOneLinkFromBrowserText() {
        assertEquals("https://example.com/story?q=one#part", SharedArticles.parse(" https://example.com/story?q=one#part ").url)
        assertEquals("https://example.com/story", SharedArticles.parse("Read this: (https://example.com/story).").url)
        assertEquals("https://example.com/wiki/Foo_(bar)", SharedArticles.parse("Read https://example.com/wiki/Foo_(bar)").url)
        assertEquals("http://example.com", SharedArticles.parse("http://example.com").url)
    }
    @Test fun rejectsAmbiguousOrUnsafeShares() {
        listOf("https://one.example https://two.example", "content://secret/file", "file:///private", "javascript:alert(1)",
            "https://user:password@example.com", "No link here").forEach { assertTrue(it, runCatching { SharedArticles.parse(it) }.isFailure) }
        assertEquals("https://example.com", SharedArticles.parse("https://example.com https://example.com").url)
    }
    @Test fun boundsHtmlByUtf8BytesAndDoesNotTruncateItSilently() {
        assertTrue(runCatching { SharedArticles.parse("https://example.com", html = "é".repeat(1_000_001)) }.isFailure)
        assertTrue(runCatching { SharedArticles.parse("x".repeat(2_000_001)) }.isFailure)
    }
    @Test fun sharedHtmlPreviewIsPlainTextAndRetainsPayloadForBackendSanitization() {
        val html = "<script>bad()</script><style>hidden</style><form>private input</form><article><p>Hello <b>world</b>.</p></article>"
        val input = SharedArticles.parse("https://example.com", "T".repeat(600), html)
        assertEquals("Hello world.", input.preview); assertEquals(500, input.title!!.length)
        assertEquals(html, input.html); assertEquals("page", input.contentFormat)
        assertTrue(input.pending().replaceExisting)
        assertEquals(html, input.pending().html)
    }
    @Test fun browserAllowsOnlyCredentialFreeSecureWebUrls() {
        assertTrue(captureWebUrl("https://example.com/article"))
        listOf("http://example.com", "file:///secret", "intent://app", "javascript:void(0)", "https://user@example.com").forEach { assertFalse(captureWebUrl(it)) }
    }
}
