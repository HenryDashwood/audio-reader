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

/** Authenticated NDJSON, with cancellation closing the socket on an IO worker. */
class HttpVoiceApi(private val baseUrl: String, private val unauthorized: (String) -> Unit = {},
    private val connect: (URL) -> HttpURLConnection = { it.openConnection() as HttpURLConnection }) : VoiceApi {
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
    override fun events(token: String, request: VoiceRequest): Flow<VoiceEvent> = callbackFlow {
        val connection = connection("command/stream", token, "POST")
        val worker = launch {
            try {
                connection.doOutput = true
                connection.setRequestProperty("Content-Type", "application/json")
                connection.outputStream.use { it.write(VoiceWire.request(request).toString().toByteArray(Charsets.UTF_8)) }
                checkStatus(connection, token)
                connection.inputStream.bufferedReader(Charsets.UTF_8).use { reader ->
                    VoiceLines.read(reader) { line ->
                        VoiceWire.event(line)?.let { event ->
                            // A slow UI consumer applies backpressure rather than dropping deltas.
                            trySendBlocking(event).getOrThrow()
                        }
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
