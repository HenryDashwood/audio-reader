package com.henrydashwood.magpie.ui

import org.junit.Assert.assertEquals
import org.junit.Test

class MonogramStyleTest {
    @Test fun initialsMatchIOS() {
        assertEquals("SW", MonogramStyle.initials("Simon Willison's Weblog"))
        assertEquals("D", MonogramStyle.initials("The Diff"))
        assertEquals("RI", MonogramStyle.initials("The Rest Is History"))
        assertEquals("I", MonogramStyle.initials("ianVisits"))
        assertEquals("MR", MonogramStyle.initials("Marginal REVOLUTION"))
    }
    /** Hues computed by the Swift implementation, so a show is the same colour on both phones. */
    @Test fun huesMatchIOS() {
        for ((title, degrees) in listOf("ianVisits" to 79, "Marginal REVOLUTION" to 65, "Café 🐦 Notes" to 39))
            assertEquals(title, degrees, Math.round(MonogramStyle.hue(title) * 360))
    }
}
