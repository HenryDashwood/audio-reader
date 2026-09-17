package com.henrydashwood.magpie.voice

import java.net.HttpURLConnection
import java.net.URI
import java.net.URL
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.channels.trySendBlocking
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject

/** Authenticated NDJSON, with cancellation closing the socket on an IO worker. */
class HttpVoiceApi(private val baseUrl: String, private val unauthorized: (String) -> Unit = {},
    private val connect: (URL) -> HttpURLConnection = { it.openConnection() as HttpURLConnection }) : VoiceApi, com.henrydashwood.magpie.data.LibraryActionApi {
    private fun connection(path: String, token: String, method: String): HttpURLConnection {
        val uri = URI(baseUrl.trimEnd('/') + "/" + path)
        require(uri.scheme == "https" && uri.host != null && uri.userInfo == null && uri.query == null && uri.fragment == null)
        return connect(uri.toURL()).apply {
            requestMethod = method
            instanceFollowRedirects = false
            connectTimeout = 15_000
            readTimeout = 300_000
            setRequestProperty("Authorization", "Bearer $token")
            setRequestProperty("Accept", "application/x-ndjson")
        }
    }
    override fun events(token: String, request: VoiceRequest): Flow<VoiceEvent> = exchange(token, "command/stream", VoiceWire.request(request), stream = true)

    override suspend fun libraryAction(token: String, action: String, episodeId: Int?, requestId: String): VoiceResponse {
        require(action in setOf("mark_played", "dismiss", "restore", "undo"))
        require(if (action == "undo") episodeId == null else episodeId != null && episodeId > 0)
        require(requestId.matches(Regex("[a-zA-Z0-9-]{1,64}")))
        return VoiceExecution.response(exchange(token, "actions", JSONObject().put("action", action)
            .put("episode_id", episodeId).put("request_id", requestId), stream = false))
    }
    override suspend fun cancelLibraryAction(token: String, requestId: String) = cancel(token, requestId)

    private fun exchange(token: String, path: String, body: JSONObject, stream: Boolean): Flow<VoiceEvent> = callbackFlow {
        val connection = connection(path, token, "POST")
        body.optString("request_id").takeIf { it.isNotBlank() }?.let {
            connection.setRequestProperty("traceparent", com.henrydashwood.magpie.telemetry.telemetryTrace(it))
        }
        if (!stream) { connection.readTimeout = 30_000; connection.setRequestProperty("Accept", "application/json") }
        val worker = launch {
            try {
                connection.doOutput = true
                connection.setRequestProperty("Content-Type", "application/json")
                connection.outputStream.use { it.write(body.toString().toByteArray(Charsets.UTF_8)) }
                checkStatus(connection, token)
                connection.inputStream.bufferedReader(Charsets.UTF_8).use { reader ->
                    if (stream) VoiceLines.read(reader) { line ->
                        VoiceWire.event(line)?.let { event ->
                            // A slow UI consumer applies backpressure rather than dropping deltas.
                            trySendBlocking(event).getOrThrow()
                        }
                    } else {
                        val text = StringBuilder(); val buffer = CharArray(4096)
                        while (true) {
                            val count = reader.read(buffer)
                            if (count < 0) break
                            if (text.length + count > VoiceLines.MAX_LINE) throw VoiceFailure(VoiceExecution.UNCONFIRMED)
                            text.append(buffer, 0, count)
                        }
                        val receipt = try { VoiceWire.response(JSONObject(text.toString())) }
                            catch (failure: Exception) { throw VoiceFailure(VoiceExecution.UNCONFIRMED, failure) }
                        trySendBlocking(VoiceEvent.Result(receipt)).getOrThrow()
                    }
                }
                close()
            } catch (cancelled: CancellationException) { close(cancelled) }
            catch (failure: VoiceFailure) { close(failure) }
            catch (failure: Exception) {
                close(VoiceFailure("I cannot reach the internet right now. Please try again shortly.", failure))
            }
        }
        // flowOn puts both the blocking reader and this cleanup on Dispatchers.IO.
        // No authorization follows a redirect, and cancellation does not leave the reader alive.
        awaitClose { connection.disconnect(); worker.cancel() }
    }.flowOn(Dispatchers.IO)

    override suspend fun cancel(token: String, requestId: String) = withContext(Dispatchers.IO) {
        require(requestId.matches(Regex("[a-zA-Z0-9-]{1,64}")))
        val connection = connection("command/$requestId", token, "DELETE")
        connection.readTimeout = 15_000
        try { checkStatus(connection, token) } finally { connection.disconnect() }
    }
    private suspend fun checkStatus(connection: HttpURLConnection, token: String) {
        val status = connection.responseCode
        if (status in 200..299) return
        if (status == 401) withContext(Dispatchers.Main) { unauthorized(token) }
        val body = connection.errorStream?.use { stream ->
            val bytes = ByteArray(64_000)
            var count = 0
            while (count < bytes.size) {
                val next = stream.read(bytes, count, bytes.size - count)
                if (next < 0) break
                count += next
            }
            String(bytes, 0, count, Charsets.UTF_8)
        }.orEmpty()
        throw VoiceFailure(VoiceWire.failure(body))
    }
}
