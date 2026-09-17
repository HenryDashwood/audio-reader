package com.henrydashwood.magpie

import com.henrydashwood.magpie.auth.AccountFailure
import com.henrydashwood.magpie.data.*
import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.io.ByteArrayOutputStream
import java.net.HttpURLConnection
import java.net.URL

class PodcastProgressWireTest {
    private class Connection(url: URL, private val payload: String, private val status: Int) : HttpURLConnection(url) {
        val body = ByteArrayOutputStream()
        var closed = false
        override fun connect() {}
        override fun disconnect() { closed = true }
        override fun usingProxy() = false
        override fun getOutputStream() = body
        override fun getInputStream() = payload.byteInputStream()
        override fun getErrorStream() = inputStream
        override fun getResponseCode() = status
    }
    @Test fun exactReportUsesGuardedRouteAndPreservesBothAcceptedAndCurrentRevisions() = runBlocking {
        val connections = mutableListOf<Connection>()
        val accepted = "a".repeat(64); var current = accepted
        val api = HttpLibraryApi("https://progress.invalid", connect = { url ->
            Connection(url, """{"accepted_revision":"$accepted","episode":{"id":4,"title":"Podcast","audio_url":"https://progress.invalid/audio.mp3","position_seconds":12.5,"completed":false,"progress_revision":"$current"}}""", 200).also { connections += it }
        })
        val report = PodcastProgressReport("b".repeat(64), 12.5, false, "same-request")
        assertFalse(api.podcastProgress("session", 4, report).changedSinceAcceptance)
        current = "c".repeat(64)
        val retried = api.podcastProgress("session", 4, report)
        assertTrue(retried.changedSinceAcceptance); assertEquals(accepted, retried.acceptedRevision)
        assertEquals(connections[0].body.toString("UTF-8"), connections[1].body.toString("UTF-8"))
        val sent = JSONObject(connections[0].body.toString("UTF-8"))
        assertEquals("same-request", sent.getString("request_id")); assertEquals(report.expectedRevision, sent.getString("expected_revision"))
        assertEquals(12.5, sent.getDouble("position_seconds"), 0.0); assertFalse(sent.getBoolean("completed"))
        assertTrue(connections.all { it.url.path == "/episodes/4/progress" && it.requestMethod == "PUT" && it.closed &&
            !it.instanceFollowRedirects && it.getRequestProperty("Authorization") == "Bearer session" })
        assertNull(HttpLibraryApi.decodeEpisode(JSONObject("""{"id":1,"title":"Old payload"}""")).progressRevision)
    }
    @Test fun conflictsAndMalformedAcknowledgementsNeverBecomeSuccessfulWrites() = runBlocking {
        var status = 409
        var payload = """{"detail":{"spoken_response":"Newer progress was kept."}}"""
        var calls = 0
        val api = HttpLibraryApi("https://progress.invalid", connect = { url -> calls++; Connection(url, payload, status) })
        val report = PodcastProgressReport("a".repeat(64), 20.0, false)
        val failure = runCatching { api.podcastProgress("session", 4, report) }.exceptionOrNull()
        assertEquals(409, (failure as AccountFailure).status); assertEquals("Newer progress was kept.", failure.message)
        status = 200
        payload = """{"accepted_revision":"bad","episode":{"id":5,"title":"Wrong item"}}"""
        assertTrue(runCatching { api.podcastProgress("session", 4, report) }.isFailure)
        assertTrue(runCatching { api.podcastProgress("session", -1, report) }.isFailure)
        assertTrue(runCatching { PodcastProgressReport("a".repeat(64), Double.NaN, false) }.isFailure)
        assertEquals(2, calls)
    }
}
