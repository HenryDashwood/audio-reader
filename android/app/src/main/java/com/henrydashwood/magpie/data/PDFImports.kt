package com.henrydashwood.magpie.data

import android.content.Context
import android.net.Uri
import android.provider.OpenableColumns
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.File
import java.net.HttpURLConnection
import java.net.URI
import java.net.URLEncoder
import java.util.UUID

const val PDF_MAX_BYTES = 25 * 1024 * 1024

data class PDFCapability(val enabled: Boolean, val consented: Boolean)
data class PendingPDF(val id: String, val owner: String, val filename: String)

class PDFClient(private val baseUrl: String, private val token: String,
    private val connect: (java.net.URL) -> HttpURLConnection = { it.openConnection() as HttpURLConnection }) {
    suspend fun capability(): PDFCapability = decode(request("capability"))
    suspend fun consent(granted: Boolean): PDFCapability = decode(request("consent", "PUT", JSONObject().put("granted", granted).toString().toByteArray()))
    suspend fun resolve(url: String): Boolean = request("resolve", "POST", JSONObject().put("url", url).toString().toByteArray()).optBoolean("pdf")
    suspend fun upload(bytes: ByteArray, filename: String) {
        require(bytes.size <= PDF_MAX_BYTES) { "Choose a PDF no larger than 25 MiB." }
        val result = request("file?filename=${URLEncoder.encode(filename, "UTF-8")}", "POST", bytes, "application/pdf")
        require(result.optString("document_id").isNotBlank()) { "The server did not confirm the PDF. Retry the upload." }
    }
    suspend fun delete(id: String) {
        require(id.matches(Regex("[a-zA-Z0-9-]+")))
        request(id, "DELETE")
    }
    private fun decode(json: JSONObject) = PDFCapability(json.optBoolean("enabled"), json.optBoolean("consented"))
    private suspend fun request(path: String, method: String = "GET", bytes: ByteArray? = null,
        contentType: String = "application/json"): JSONObject = withContext(Dispatchers.IO) {
        val url = URI(baseUrl.trimEnd('/') + "/documents/" + path)
        require(url.scheme == "https" && url.userInfo == null)
        val connection = connect(url.toURL())
        try {
            connection.requestMethod = method
            connection.instanceFollowRedirects = false
            connection.useCaches = false
            connection.connectTimeout = 15_000
            connection.readTimeout = 90_000
            connection.setRequestProperty("Authorization", "Bearer $token")
            if (bytes != null) {
                connection.doOutput = true
                connection.setFixedLengthStreamingMode(bytes.size)
                connection.setRequestProperty("Content-Type", contentType)
                connection.outputStream.use { it.write(bytes) }
            }
            val status = connection.responseCode
            val input = if (status in 200..299) connection.inputStream else connection.errorStream
            val raw = input?.use { stream ->
                val out = ByteArrayOutputStream()
                val buffer = ByteArray(8192)
                while (true) {
                    val n = stream.read(buffer)
                    if (n < 0) break
                    require(out.size() + n <= 2_000_000) { "PDF response too large." }
                    out.write(buffer, 0, n)
                }
                out.toString("UTF-8")
            }.orEmpty()
            val json = if (raw.isBlank()) JSONObject() else JSONObject(raw)
            check(status in 200..299) { json.opt("detail") as? String ?: "PDF importing is unavailable for this account or server." }
            json
        } finally { connection.disconnect() }
    }
}

/** Durable local copies are bound to the initiating library owner, which includes its server. */
class PDFUploadInbox(private val context: Context) {
    private val directory get() = File(context.filesDir, "pdf-inbox").also { it.mkdirs() }
    suspend fun add(uri: Uri, owner: String): PendingPDF = withContext(Dispatchers.IO) {
        require(uri.scheme == "content") { "Choose a PDF from your document provider." }
        val filename = context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use {
            if (it.moveToFirst()) it.getString(0) else null
        }?.take(500) ?: "Document.pdf"
        val data = context.contentResolver.openInputStream(uri)?.use { input ->
            val out = ByteArrayOutputStream()
            val buffer = ByteArray(64 * 1024)
            while (true) {
                val n = input.read(buffer)
                if (n < 0) break
                require(out.size() + n <= PDF_MAX_BYTES) { "Choose a PDF no larger than 25 MiB." }
                out.write(buffer, 0, n)
            }
            out.toByteArray()
        } ?: error("The PDF could not be opened.")
        require(data.take(1024).toByteArray().toString(Charsets.ISO_8859_1).contains("%PDF-")) { "Choose a valid PDF." }
        val item = PendingPDF(UUID.randomUUID().toString(), owner, filename)
        val file = File(directory, "${item.id}.pdf")
        file.outputStream().use { it.write(data); it.fd.sync() }
        val metadata = JSONObject().put("id", item.id).put("owner", owner).put("filename", filename).toString()
        val atomic = android.util.AtomicFile(File(directory, "${item.id}.json"))
        val output = atomic.startWrite()
        try { output.write(metadata.toByteArray()); atomic.finishWrite(output) }
        catch (error: Exception) { atomic.failWrite(output); file.delete(); throw error }
        item
    }
    suspend fun pending(owner: String): List<PendingPDF> = withContext(Dispatchers.IO) {
        directory.listFiles().orEmpty().filter { it.extension == "json" }.mapNotNull { file ->
            runCatching {
                val json = JSONObject(file.readText())
                PendingPDF(json.getString("id"), json.getString("owner"), json.getString("filename"))
            }.getOrNull()?.takeIf { it.owner == owner && it.id.matches(Regex("[a-zA-Z0-9-]+")) }
        }
    }
    suspend fun bytes(item: PendingPDF): ByteArray = withContext(Dispatchers.IO) {
        val file = File(directory, "${item.id}.pdf")
        require(file.length() <= PDF_MAX_BYTES)
        file.readBytes()
    }
    suspend fun remove(item: PendingPDF) = withContext(Dispatchers.IO) {
        File(directory, "${item.id}.json").delete()
        File(directory, "${item.id}.pdf").delete()
        Unit
    }
}
