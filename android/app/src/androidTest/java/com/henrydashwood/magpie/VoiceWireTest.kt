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
    @Test fun clarificationWireRoundTripPreservesChoiceIDsAndTimezone() {
        val json = JSONObject("""{"action":"unknown","spoken_response":"Which?","expects_reply":true,
            "status":"needs_clarification","clarification":{"id":"q1","question":"Which?",
            "expires_at":"2099-01-01T00:00:00Z","choices":[{"id":"20","label":"Politics"}]}}""")
        val question = VoiceWire.response(json).clarification!!
        val body = VoiceWire.request(VoiceRequest("Politics", clarificationId = question.id,
            selectedOptionId = question.choices.single().id, timezone = "Europe/London"))
        assertEquals("q1", body.getString("clarification_id"))
        assertEquals("20", body.getString("selected_option_id"))
        assertEquals("Europe/London", body.getString("timezone"))
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
    @Test fun typedFilingUsesTheExistingActionsContractAndDecodesItsReceipt() = runBlocking {
        lateinit var connection: Connection
        val payload = """{
          "action":"mark_played", "spoken_response":"Marked as played.",
          "episode":{"id":2,"title":"Example","completed":true,"position_seconds":0}
        }"""
        val api = HttpVoiceApi("https://voice.invalid", connect = { url -> Connection(url, payload.byteInputStream()).also { connection = it } })
        val result = api.libraryAction("original-account", "mark_played", 2, "filing-1")
        assertEquals("https://voice.invalid/actions", connection.url.toString()); assertEquals("POST", connection.requestMethod)
        assertEquals("application/json", connection.getRequestProperty("Accept"))
        assertEquals("Bearer original-account", connection.getRequestProperty("Authorization")); assertFalse(connection.instanceFollowRedirects)
        val body = JSONObject(connection.body.toString("UTF-8"))
        assertEquals(setOf("action", "episode_id", "request_id"), body.keys().asSequence().toSet())
        assertEquals("mark_played", body.getString("action")); assertEquals(2, body.getInt("episode_id")); assertEquals("filing-1", body.getString("request_id"))
        assertEquals(VoiceAction.Played, result.action); assertTrue(result.episode!!.completed); assertTrue(connection.disconnected)
    }
    @Test fun typedActionsRejectInvalidRequestsRedirectsAndUnauthorizedResponses() = runBlocking {
        var requests = 0
        val rejected = mutableListOf<String>()
        val api = HttpVoiceApi("https://voice.invalid", rejected::add, connect = { url ->
            requests++; Connection(url, "".byteInputStream(), 401, "{\"detail\":{\"spoken_response\":\"Sign in again\"}}")
        })
        for ((action, id, requestId) in listOf(Triple("invalid", 1, "id"), Triple("mark_played", null, "id"), Triple("undo", null, "../id")))
            assertTrue(runCatching { api.libraryAction("one", action, id, requestId) }.isFailure)
        assertEquals(0, requests)
        assertEquals("Sign in again", runCatching { api.libraryAction("one", "undo", null, "undo-1") }.exceptionOrNull()!!.message)
        assertEquals(listOf("one"), rejected)
        val redirect = HttpVoiceApi("https://voice.invalid", connect = { url -> requests++; Connection(url, "".byteInputStream(), 302) })
        assertTrue(runCatching { redirect.libraryAction("one", "undo", null, "undo-2") }.exceptionOrNull() is VoiceFailure)
        assertEquals(2, requests)
    }
    @Test fun cancellingTypedFilingDisconnectsItsReaderAndUsesTheOriginalRequestForCancellation() = runBlocking {
        val reading = CountDownLatch(1); val closed = CountDownLatch(1)
        val input = object : InputStream() {
            override fun read(): Int { reading.countDown(); closed.await(10, TimeUnit.SECONDS); return -1 }
            override fun close() { closed.countDown() }
        }
        val connections = mutableListOf<Connection>()
        val api = HttpVoiceApi("https://voice.invalid", connect = { url ->
            Connection(url, if (url.path == "/actions") input else "".byteInputStream()).also { connections += it }
        })
        var completed = false
        val pending = launch(Dispatchers.Default) { api.libraryAction("original", "dismiss", 2, "filing-2"); completed = true }
        assertTrue(reading.await(5, TimeUnit.SECONDS)); withTimeout(5_000) { pending.cancelAndJoin() }
        assertTrue(connections.first().disconnected); assertFalse(completed)
        api.cancelLibraryAction("original", "filing-2")
        val cancel = connections.last()
        assertEquals("DELETE", cancel.requestMethod); assertEquals("/command/filing-2", cancel.url.path)
        assertEquals("Bearer original", cancel.getRequestProperty("Authorization"))
    }
    @Test fun malformedAndOversizedTypedReceiptsNeverConfirmAMutation() = runBlocking {
        for (body in listOf("{", "{\"action\":\"mark_played\",\"spoken_response\":\"Done\"}", " ".repeat(VoiceLines.MAX_LINE + 1))) {
            val api = HttpVoiceApi("https://voice.invalid", connect = { url -> Connection(url, body.byteInputStream()) })
            assertTrue(runCatching { api.libraryAction("one", "mark_played", 2, "filing-3") }.exceptionOrNull() is VoiceFailure)
        }
    }
}
