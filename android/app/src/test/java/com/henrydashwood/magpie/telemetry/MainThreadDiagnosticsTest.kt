package com.henrydashwood.magpie.telemetry

import org.junit.Assert.*
import org.junit.Test

class MainThreadDiagnosticsTest {
    @Test fun foregroundFreezeNeedsFiveSecondsAndTheSameSession() {
        assertNull(mainThreadHangSeconds(1_000, 5_999, true, true))
        assertEquals(5.0, mainThreadHangSeconds(1_000, 6_000, true, true))
        assertNull(mainThreadHangSeconds(1_000, 60_000, false, true))
        assertNull(mainThreadHangSeconds(1_000, 60_000, true, false))
        assertNull(mainThreadHangSeconds(2_000, 1_000, true, true))
    }
}
