package com.henrydashwood.magpie

import com.henrydashwood.magpie.data.*
import com.henrydashwood.magpie.auth.AccountFailure
import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.net.HttpURLConnection
import java.net.URL

class NewsletterWireTest {
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
    @Test fun authenticatedNewsletterRoutesMatchTheExistingServerContract() = runBlocking {
        val connections = mutableListOf<Connection>()
        val api = HttpLibraryApi("https://newsletter.invalid", connect = { url ->
            val body = when (url.path) {
                "/newsletters/address" -> """{"address":"quiet-heron@magpie.example"}"""
                "/newsletters/pending" -> """[{"id":8,"title":"Morning","sender_address":"editor@example.com","message_count":2,"latest_title":"Today","latest_at":"2026-09-17T08:00:00Z"}]"""
                "/newsletters/8/approve" -> """{"id":8,"title":"Morning","episode_count":2,"is_article_feed":true}"""
                "/newsletters/8/block" -> ""
                else -> error("Unexpected URL")
            }
            Connection(url, body, if (url.path.endsWith("/block")) 204 else 200).also { connections += it }
        })
        assertEquals("quiet-heron@magpie.example", api.newsletterAddress("session").address)
        val sender = api.pendingNewsletters("session").single()
        assertEquals(8, sender.id); assertEquals("Today", sender.latestTitle); assertEquals("2 messages", sender.messageCountLabel)
        assertTrue(api.approveNewsletter("session", 8).articles)
        api.blockNewsletter("session", 8)
        assertEquals(listOf("GET", "GET", "POST", "POST"), connections.map { it.requestMethod })
        assertTrue(connections.all { it.closed && !it.instanceFollowRedirects && it.getRequestProperty("Authorization") == "Bearer session" })
        assertTrue(runCatching { api.blockNewsletter("session", -1) }.isFailure)
        assertEquals(4, connections.size)
    }
    @Test fun signupHasALongerDeadlineAndPreservesManualFallbackAndSubmittedReplies() = runBlocking {
        var status = "unsupported"
        lateinit var connection: Connection
        val api = HttpLibraryApi("https://newsletter.invalid", connect = { url ->
            Connection(url, """{"status":"$status","publication":"Morning","platform":"custom","address":"quiet-heron@magpie.example","reason":"captcha","spoken_response":"Use this address on the website."}""").also { connection = it }
        })
        val result = api.signUpForNewsletter("session", "https://publisher.example")
        assertFalse(result.submitted); assertEquals("captcha", result.reason); assertNotNull(result.address)
        assertEquals("/newsletters/signups", connection.url.path); assertEquals("POST", connection.requestMethod)
        assertEquals("https://publisher.example", JSONObject(connection.body.toString("UTF-8")).getString("url"))
        assertEquals(60_000, connection.readTimeout)
        status = "submitted"
        assertTrue(api.signUpForNewsletter("session", "https://publisher.example").submitted)
    }
    @Test fun unavailableAndUnauthorizedRepliesPreserveExplanationAndNeverFollowRedirects() = runBlocking {
        var status = 503
        var requests = 0
        val rejected = mutableListOf<String>()
        val api = HttpLibraryApi("https://newsletter.invalid", rejected::add, connect = { url ->
            requests++; Connection(url, """{"detail":{"spoken_response":"Newsletters are unavailable."}}""", status)
        })
        assertEquals("Newsletters are unavailable.", runCatching { api.newsletterAddress("old") }.exceptionOrNull()!!.message)
        status = 401; assertTrue(runCatching { api.newsletterAddress("old") }.exceptionOrNull() is AccountFailure)
        assertEquals(listOf("old"), rejected)
        status = 302; assertTrue(runCatching { api.newsletterAddress("old") }.isFailure)
        assertEquals(3, requests)
    }
}
