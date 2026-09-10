package com.henrydashwood.magpie.data

import org.junit.Assert.*
import org.junit.Test

class LinkValidationTest {
    @Test fun acceptsWebLinksWithoutChangingTheirPathOrQuery() {
        listOf("https://example.org/story?q=a%20b#part", "http://example.org:8080/article", "HTTPS://example.org/Story").forEach {
            assertEquals(it, validateLink("  $it  "))
        }
    }
    @Test fun rejectsNonWebAndMalformedAddresses() {
        listOf("", "example.org/story", "https://", "https://example.org/a b", "file:///etc/passwd", "javascript:alert(1)",
            "https://name:password@example.org/story", "https://example.org:99999/story").forEach {
            assertThrows(it, IllegalArgumentException::class.java) { validateLink(it) }
        }
    }
}
