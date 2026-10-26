package com.henrydashwood.magpie

import com.henrydashwood.magpie.data.PDFClient
import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.net.HttpURLConnection
import java.net.URL

class PDFImportWireTest {
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

    @Test fun pdfUrlClassificationPreservesSignedLinksAndSession() = runBlocking {
        lateinit var connection: Connection
        val api = PDFClient("https://magpie.invalid", "owner-token") { url ->
            Connection(url, """{"pdf":true}""").also { connection = it }
        }
        val url = "https://papers.example/download?token=one%2Btwo&id=3"
        assertTrue(api.resolve(url))
        assertEquals(url, JSONObject(connection.body.toString("UTF-8")).getString("url"))
        assertEquals("/documents/resolve", connection.url.path)
        assertEquals("Bearer owner-token", connection.getRequestProperty("Authorization"))
        assertFalse(connection.instanceFollowRedirects)
        assertTrue(connection.closed)
    }

    @Test fun uploadUsesRawPdfAndRequiresADurableReceipt() = runBlocking {
        lateinit var connection: Connection
        var response = """{"id":42,"document_id":"pdf-42","document_status":"queued"}"""
        val api = PDFClient("https://magpie.invalid", "owner-token") { url ->
            Connection(url, response, 202).also { connection = it }
        }
        val bytes = "%PDF-1.7\nfixture".toByteArray()
        api.upload(bytes, "Study & notes.pdf")
        assertArrayEquals(bytes, connection.body.toByteArray())
        assertEquals("application/pdf", connection.getRequestProperty("Content-Type"))
        assertEquals("filename=Study+%26+notes.pdf", connection.url.query)
        response = "{}"
        assertTrue(runCatching { api.upload(bytes, "Study.pdf") }.isFailure)
    }

    @Test fun unavailableAccountAndRedirectsDoNotConfirmAnUpload() = runBlocking {
        var status = 403
        val api = PDFClient("https://magpie.invalid", "other-account") { url ->
            Connection(url, """{"detail":"PDF importing is not enabled for this account."}""", status)
        }
        assertEquals("PDF importing is not enabled for this account.", runCatching { api.capability() }.exceptionOrNull()?.message)
        status = 302
        assertTrue(runCatching { api.upload("%PDF-1.7".toByteArray(), "Study.pdf") }.isFailure)
    }
}
