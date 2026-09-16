package com.henrydashwood.magpie

import com.henrydashwood.magpie.voice.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.toList
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

class VoiceWireTest {
    private val request = VoiceRequest("Read this", requestId = "request-1", viewedEpisodeId = 2, nowPlayingEpisodeId = 3,
        turns = listOf(ConversationTurn("app", "Which one?")), recentActions = listOf("subscribed: Example"), country = "GB")
    private val receipt = """{"type":"result","response":{"action":"play_episode","spoken_response":"Reading it.","episode":{"id":2,"title":"Example","link":"https://example.com","has_text":true,"content_id":7},"expects_reply":false}}"""
    private class Connection(url: URL, private val payload: InputStream, val status: Int = 200,
        private val error: String = "") : HttpURLConnection(url) {
        val body = ByteArrayOutputStream()
        @Volatile var disconnected = false
        override fun connect() {}
        override fun disconnect() { disconnected = true; payload.close() }
        override fun usingProxy() = false
        override fun getOutputStream() = body
        override fun getInputStream() = payload
        override fun getResponseCode() = status
        override fun getErrorStream() = ByteArrayInputStream(error.toByteArray())
    }
    @Test fun requestUsesExistingSwiftContractAndStreamDeliversFinalEpisode() = runBlocking {
        lateinit var connection: Connection
        val api = HttpVoiceApi("https://voice.invalid", connect = { url ->
            Connection(url, ByteArrayInputStream(("{\"type\":\"assistant_delta\",\"text\":\"Reading 🐦\"}\n" + receipt).toByteArray())).also { connection = it }
        })
        val events = api.events("session", request).toList()
        assertEquals(2, events.size); assertEquals(VoiceEvent.Delta("Reading 🐦"), events.first())
        val result = (events.last() as VoiceEvent.Result).response
        assertEquals(VoiceAction.Play, result.action); assertEquals(7, result.episode!!.contentId)
        assertEquals("https://voice.invalid/command/stream", connection.url.toString())
        assertEquals("POST", connection.requestMethod); assertFalse(connection.instanceFollowRedirects)
        assertEquals("Bearer session", connection.getRequestProperty("Authorization"))
        val json = JSONObject(connection.body.toString("UTF-8"))
        assertTrue(json.getBoolean("supports_compound_actions")); assertEquals("request-1", json.getString("request_id"))
        assertEquals(2, json.getInt("viewed_episode_id")); assertEquals(3, json.getInt("now_playing_episode_id"))
        assertEquals("gb", json.getString("country")); assertEquals("app", json.getJSONArray("turns").getJSONObject(0).getString("speaker"))
        assertEquals("subscribed: Example", json.getJSONArray("recent_actions").getString(0))
        assertTrue(connection.disconnected)
    }
    @Test fun malformedIncompleteAndErrorEnvelopesCannotProduceAReceipt() {
        listOf("{", "{\"type\":\"result\"}", "{\"type\":\"result\",\"response\":{\"action\":\"set_speed\",\"spoken_response\":\"Faster\"}}",
            "{\"type\":\"result\",\"response\":{\"action\":\"play_episode\",\"spoken_response\":\"Playing\"}}",
            "{\"type\":\"error\",\"spoken_response\":\"Service unavailable\"}").forEach {
            assertTrue(it, runCatching { VoiceWire.event(it) }.exceptionOrNull() is VoiceFailure)
        }
        assertNull(VoiceWire.event("{\"type\":\"keepalive\"}"))
        val unknown = VoiceWire.event("{\"type\":\"result\",\"response\":{\"action\":\"future\",\"spoken_response\":\"Done\"}}") as VoiceEvent.Result
        assertEquals(VoiceAction.Unknown, unknown.response.action)
    }
    @Test fun compoundActionsAndSpokenQuestionsRemainDistinctFromTheirSummary() {
        val result = VoiceWire.event("""{"type":"result","response":{"action":"unknown","spoken_response":"Done. What next?","expects_reply":true,"actions":[{"action":"set_speed","speed":1.5,"spoken_response":"Faster"},{"action":"subscribed","spoken_response":"Subscribed"}]}}""") as VoiceEvent.Result
        assertTrue(result.response.expectsReply)
        assertEquals(listOf(VoiceAction.Speed, VoiceAction.Subscribed), result.response.effects.map { it.action })
    }
    @Test fun unauthorizedAndRedirectResponsesNeverForwardAuthorization() = runBlocking {
        val rejected = mutableListOf<String>()
        var requests = 0
        val api = HttpVoiceApi("https://voice.invalid", rejected::add, connect = { url ->
            requests++
            Connection(url, ByteArrayInputStream(byteArrayOf()), 401, "{\"detail\":{\"spoken_response\":\"Sign in again\"}}")
        })
        assertEquals("Sign in again", runCatching { api.events("old-token", request).toList() }.exceptionOrNull()!!.message)
        assertEquals(listOf("old-token"), rejected); assertEquals(1, requests)
        val redirect = HttpVoiceApi("https://voice.invalid", connect = { url ->
            requests++; Connection(url, ByteArrayInputStream(byteArrayOf()), 302)
        })
        assertTrue(runCatching { redirect.events("token", request).toList() }.exceptionOrNull() is VoiceFailure)
        assertEquals(2, requests)
    }
    @Test fun cancellationDisconnectsABlockedReaderAndDoesNotEmitASuccess() = runBlocking {
        val reading = CountDownLatch(1); val closed = CountDownLatch(1)
        val input = object : InputStream() {
            override fun read(): Int { reading.countDown(); closed.await(10, TimeUnit.SECONDS); return -1 }
            override fun close() { closed.countDown() }
        }
        lateinit var connection: Connection
        val api = HttpVoiceApi("https://voice.invalid", connect = { url -> Connection(url, input).also { connection = it } })
        var completed = false
        val job = launch(Dispatchers.Default) { VoiceExecution.response(api.events("token", request)); completed = true }
        assertTrue(reading.await(5, TimeUnit.SECONDS))
        withTimeout(5_000) { job.cancelAndJoin() }
        assertTrue(connection.disconnected); assertFalse(completed)
    }
    @Test fun cancelUsesTheOriginalRequestIdAndRejectsPathInjection() = runBlocking {
        lateinit var connection: Connection
        val api = HttpVoiceApi("https://voice.invalid", connect = { url -> Connection(url, ByteArrayInputStream(byteArrayOf())).also { connection = it } })
        api.cancel("token", request.requestId)
        assertEquals("https://voice.invalid/command/request-1", connection.url.toString())
        assertEquals("DELETE", connection.requestMethod); assertTrue(connection.disconnected)
        assertTrue(runCatching { api.cancel("token", "../me") }.isFailure)
    }
}
