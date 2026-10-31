package com.henrydashwood.magpie

import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.core.content.IntentCompat
import androidx.test.core.app.ApplicationProvider
import com.henrydashwood.magpie.data.HttpLibraryApi
import com.henrydashwood.magpie.sharing.*
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.File
import java.net.HttpURLConnection
import java.net.URL

class ArticleExportWireTest {
    private class Connection(url: URL, val payload: String = "%PDF-1.7\nfixture", val mime: String = "application/pdf",
                             val status: Int = 200) : HttpURLConnection(url) {
        var closed = false
        override fun connect() {}
        override fun disconnect() { closed = true }
        override fun usingProxy() = false
        override fun getResponseCode() = status
        override fun getContentType() = mime
        override fun getContentLengthLong() = payload.toByteArray().size.toLong()
        override fun getInputStream() = ByteArrayInputStream(payload.toByteArray())
        override fun getErrorStream() = inputStream
    }

    @Test fun authenticatedSelectedVersionStreamsToFileAndProviderGrantsOnlyThatFile() = runBlocking {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val file = articlePdfDestination(context, "../../科学: A/B")
        var connection: Connection? = null
        val api = HttpLibraryApi("https://example.org", connect = { Connection(it).also { connection = it } })
        try {
            api.exportArticle("captured", 12, 34, "a".repeat(64), file)
            assertEquals("科学 AB.pdf", file.name)
            assertEquals("%PDF-1.7\nfixture", file.readText())
            val request = checkNotNull(connection)
            assertEquals("/episodes/12/export.pdf", request.url.path)
            assertTrue(request.url.query.contains("content_id=34"))
            assertTrue(request.url.query.contains("text_version=" + "a".repeat(64)))
            assertEquals("Bearer captured", request.getRequestProperty("Authorization"))
            assertEquals("application/pdf", request.getRequestProperty("Accept"))
            assertFalse(request.instanceFollowRedirects)
            assertFalse(request.useCaches)
            assertTrue(request.closed)
            val uri = articlePdfUri(context, file)
            assertEquals("content", uri.scheme)
            assertEquals(file.readText(), context.contentResolver.openInputStream(uri)!!.bufferedReader().use { it.readText() })
            val chooser = articlePdfShareIntent(uri, "Title")
            val send = checkNotNull(IntentCompat.getParcelableExtra(chooser, Intent.EXTRA_INTENT, Intent::class.java))
            assertEquals("application/pdf", send.type)
            assertEquals(uri, IntentCompat.getParcelableExtra(send, Intent.EXTRA_STREAM, Uri::class.java))
            assertEquals(uri, send.clipData!!.getItemAt(0).uri)
            assertTrue(send.flags and Intent.FLAG_GRANT_READ_URI_PERMISSION != 0)
            assertTrue(chooser.flags and Intent.FLAG_GRANT_READ_URI_PERMISSION != 0)
            val privateFile = File(context.cacheDir, "private-account-cache").apply { writeText("private") }
            try { assertTrue(runCatching { articlePdfUri(context, privateFile) }.isFailure) }
            finally { privateFile.delete() }
        } finally { file.parentFile!!.deleteRecursively() }
    }

    @Test fun invalidOrFailedDownloadsLeaveNoShareablePartialFile() = runBlocking {
        val context = ApplicationProvider.getApplicationContext<Context>()
        for ((payload, mime, status) in listOf(Triple("not PDF", "application/pdf", 200),
            Triple("%PDF-1.7", "text/html", 200), Triple("{}", "application/json", 503))) {
            val file = articlePdfDestination(context, "Article")
            val api = HttpLibraryApi("https://example.org", connect = { Connection(it, payload, mime, status) })
            assertTrue(runCatching { api.exportArticle("token", 1, null, null, file) }.isFailure)
            assertFalse(file.exists())
            file.parentFile!!.deleteRecursively()
        }
    }
}
