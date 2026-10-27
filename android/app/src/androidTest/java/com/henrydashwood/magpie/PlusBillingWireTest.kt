package com.henrydashwood.magpie

import com.henrydashwood.magpie.billing.PlusClient
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test
import java.io.ByteArrayInputStream
import java.net.HttpURLConnection
import java.net.URL

class PlusBillingWireTest {
    private val payload = """{"available":true,"active":true,"unlimited":false,"customer_id":"opaque-account","google_sdk_key":"goog_public","offering_id":"magpie_plus","monthly_pages":500,"used_pages":42,"remaining_pages":458,"period_end":"2026-11-27T12:00:00Z","store":"app_store"}"""
    private class Connection(url: URL, val payload: String, val code: Int) : HttpURLConnection(url) {
        var closed = false
        override fun connect() {}
        override fun disconnect() { closed = true }
        override fun usingProxy() = false
        override fun getInputStream() = ByteArrayInputStream(payload.toByteArray())
        override fun getErrorStream() = inputStream
        override fun getResponseCode() = code
    }
    @Test fun appleEntitlementUsesAuthenticatedServerStatus() = runBlocking {
        lateinit var connection: Connection
        val client = PlusClient("https://magpie.invalid", "owner-token") { url ->
            Connection(url, payload, 200).also { connection = it }
        }
        val status = client.status(sync = true)
        assertTrue(status.active)
        assertEquals("app_store", status.store)
        assertEquals(458, status.remainingPages)
        assertEquals("/billing/sync", connection.url.path)
        assertEquals("POST", connection.requestMethod)
        assertEquals("Bearer owner-token", connection.getRequestProperty("Authorization"))
        assertFalse(connection.instanceFollowRedirects)
        assertTrue(connection.closed)
    }
    @Test fun failedVerificationCannotGrantAccess() = runBlocking {
        for (code in listOf(302, 401, 403, 429, 503)) {
            val client = PlusClient("https://magpie.invalid", "token") { Connection(it, payload, code) }
            assertTrue(runCatching { client.status() }.isFailure)
        }
    }
    @Test fun ownerUnlimitedIsNotConfusedWithAnEmptyAllowance() = runBlocking {
        val client = PlusClient("https://magpie.invalid", "owner") {
            Connection(it, payload.replace("\"unlimited\":false", "\"unlimited\":true").replace("\"remaining_pages\":458", "\"remaining_pages\":null"), 200)
        }
        val status = client.status()
        assertTrue(status.unlimited)
        assertNull(status.remainingPages)
    }
}
