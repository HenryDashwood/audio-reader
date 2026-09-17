package com.henrydashwood.magpie

import com.henrydashwood.magpie.data.*
import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.net.HttpURLConnection
import java.net.URL

class SubscriptionImportWireTest {
    private class Connection(url: URL, val payload: String, val status: Int = 200) : HttpURLConnection(url) {
        val body = ByteArrayOutputStream()
        var closed = false
        override fun connect() {}
        override fun disconnect() { closed = true }
        override fun usingProxy() = false
        override fun getOutputStream() = body
        override fun getInputStream() = ByteArrayInputStream(payload.toByteArray())
        override fun getErrorStream() = inputStream
        override fun getResponseCode() = status
    }
    private val payload = """{"id":"review","status":"draft","duplicates":1,"folders":true,"total":0,"finished":0,"added":0,"already_following":0,"failed":0,"not_imported":0,"items":[{"id":7,"title":"Café & 科学","host":"example.org","status":"ready","message":null,"selected":false,"retryable":false,"feed_id":null}]}"""
    @Test fun rawFileAndMutationsMatchBackendContract() = runBlocking {
        val calls = mutableListOf<Connection>()
        val api = HttpLibraryApi("https://import.invalid", connect = { url ->
            Connection(url, if (url.path.endsWith("current")) "null" else payload).also { calls += it }
        })
        assertNull(api.currentImport("session"))
        val bytes = "<opml><body>科学</body></opml>".toByteArray()
        assertEquals("Café & 科学", api.previewImport("session", bytes).items.single().title)
        assertArrayEquals(bytes, calls.last().body.toByteArray())
        assertEquals("application/xml", calls.last().getRequestProperty("Content-Type"))
        api.mutateImport("session", "review", "start", "stable", setOf(7))
        val json = JSONObject(calls.last().body.toString("UTF-8"))
        assertEquals("stable", json.getString("request_id"))
        assertEquals(7, json.getJSONArray("entry_ids").getInt(0))
        assertTrue(json.getBoolean("public_feeds_confirmed"))
        api.mutateImport("session", "review", "stop", null, null)
        api.mutateImport("session", "review", "retry", "retry-stable", null)
        assertEquals(listOf("/subscription-imports/current", "/subscription-imports/preview", "/subscription-imports/review/start", "/subscription-imports/review/stop", "/subscription-imports/review/retry"), calls.map { it.url.path })
        assertTrue(calls.all { it.closed && !it.instanceFollowRedirects && it.getRequestProperty("Authorization") == "Bearer session" })
    }
    @Test fun oldServersGiveUsefulErrorWithoutFollowingRedirects() = runBlocking {
        val api = HttpLibraryApi("https://import.invalid", connect = { Connection(it, "{}", 404) })
        assertTrue(runCatching { api.currentImport("session") }.exceptionOrNull()!!.message!!.contains("unavailable"))
    }
}
