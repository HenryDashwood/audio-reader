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

class ArticleProgressWireTest {
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
    @Test fun immutableTextCoordinatesUseTheirOwnRouteAndKeepCurrentAndAcceptedStateSeparate() = runBlocking {
        val version = "a".repeat(64); val accepted = "b".repeat(64); var current = accepted
        val connections = mutableListOf<Connection>()
        val api = HttpLibraryApi("https://bookmarks.invalid", connect = { url ->
            Connection(url, """{"accepted_revision":"$accepted","episode":{"id":4,"title":"Article","article_bookmark":{"text_version":"$version","offset_utf16":19}},"progress":{"revision":"$current","text_version":"$version","content_id":8,"bookmark":{"text_version":"$version","offset_utf16":19}}}""", 200).also { connections += it }
        })
        val report = ArticleProgressReport("c".repeat(64), version, 8, 9, false, "original")
        assertFalse(api.articleProgress("session", 4, report).changedSinceAcceptance)
        current = "d".repeat(64)
        val later = api.articleProgress("session", 4, report)
        assertTrue(later.changedSinceAcceptance); assertEquals(19, later.episode.articleBookmark?.offsetUtf16)
        assertEquals(connections[0].body.toString("UTF-8"), connections[1].body.toString("UTF-8"))
        val sent = JSONObject(connections[0].body.toString("UTF-8"))
        assertEquals(9, sent.getInt("offset_utf16")); assertEquals(version, sent.getString("text_version"))
        assertEquals("original", sent.getString("request_id")); assertEquals(8, sent.getInt("content_id")); assertFalse(sent.has("position_seconds"))
        assertTrue(connections.all { it.url.path == "/episodes/4/article-progress" && it.requestMethod == "PUT" &&
            it.closed && !it.instanceFollowRedirects && it.getRequestProperty("Authorization") == "Bearer session" })
    }
    @Test fun oldTextHasNoCapabilityAndInvalidBookmarksOrConflictsNeverAcknowledgeAWritingRequest() = runBlocking {
        var status = 200
        var payload = """{"episode_id":4,"title":"Article","text":"First 🌱 café"}"""
        val api = HttpLibraryApi("https://bookmarks.invalid", connect = { Connection(it, payload, status) })
        assertNull(api.text("session", 4, null).articleProgress)
        assertNull(HttpLibraryApi.decodeEpisode(JSONObject("""{"id":4,"title":"Old"}""")).articleBookmark)
        val version = "a".repeat(64)
        val report = ArticleProgressReport(version, version, null, 9, false)
        payload = """{"accepted_revision":"$version","episode":{"id":4,"title":"Article"},"progress":{"revision":"$version","text_version":"$version","bookmark":{"text_version":"$version","offset_utf16":1.5}}}"""
        assertTrue(runCatching { api.articleProgress("session", 4, report) }.isFailure)
        payload = """{"detail":{"spoken_response":"Newer text was kept."}}"""; status = 409
        val failure = runCatching { api.articleProgress("session", 4, report) }.exceptionOrNull() as AccountFailure
        assertEquals(409, failure.status)
        assertTrue(runCatching { ArticleProgressReport(version, version, null, -1, false) }.isFailure)
        assertTrue(runCatching { ArticleProgressState(version, null, version, RemoteArticleBookmark("b".repeat(64), 0)) }.isFailure)
    }
}
