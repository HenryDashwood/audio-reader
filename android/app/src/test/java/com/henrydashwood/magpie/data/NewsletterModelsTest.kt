package com.henrydashwood.magpie.data

import org.junit.Assert.*
import org.junit.Test

class NewsletterModelsTest {
    @Test fun readableAddressSaysWordsAndCanStillSpellEveryLetter() {
        val value = NewsletterAddress("quiet-heron@in.magpie.example")
        assertEquals("quiet, heron, with hyphens between the words, at in dot magpie dot example", value.spoken)
        assertEquals("q, u, i, e, t, hyphen, h, e, r, o, n, at in dot magpie dot example", value.spelledOut)
    }
    @Test fun LegacyAddressSpellsLettersAndPunctuation() {
        assertEquals("a, b, 3, dot, c, underscore, d, at mail dot example", NewsletterAddress("ab3.c_d@mail.example").spoken)
        assertEquals("a, hyphen, hyphen, b, at mail dot example", NewsletterAddress("a--b@mail.example").spoken)
    }
}
