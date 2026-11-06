package com.henrydashwood.magpie

import android.content.Intent
import android.view.accessibility.AccessibilityEvent
import androidx.activity.compose.setContent
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createEmptyComposeRule
import androidx.lifecycle.Lifecycle
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import androidx.test.platform.app.InstrumentationRegistry
import com.henrydashwood.magpie.data.PDFClient
import com.henrydashwood.magpie.ui.PDFUploadDialog
import com.henrydashwood.magpie.sharing.ShareActivity
import java.io.*
import java.net.*
import java.util.UUID
import java.util.concurrent.*
import java.util.concurrent.atomic.AtomicInteger
import org.json.JSONObject
import org.junit.*
import org.junit.Assert.*

private class UploadEndpoint {
    val owner = UUID.randomUUID().toString()
    val calls = AtomicInteger()
    val gate = CountDownLatch(1)
    val returned = CountDownLatch(1)
    var status = 202
    fun connect(url: URL): HttpURLConnection = object : HttpURLConnection(url) {
        override fun connect() {}
        override fun disconnect() { if (url.path.endsWith("/file")) returned.countDown() }
        override fun usingProxy() = false
        override fun getOutputStream() = ByteArrayOutputStream()
        override fun getResponseCode(): Int {
            if (!url.path.endsWith("/file")) return 200
            calls.incrementAndGet()
            check(gate.await(30, TimeUnit.SECONDS))
            return status
        }
        override fun getInputStream() = (if (url.path.endsWith("/file")) """{"document_id":"one"}""" else """{"enabled":true}""").byteInputStream()
        override fun getErrorStream() = """{"detail":"fixture upload failed"}""".byteInputStream()
    }
}
class PDFUploadDialogTest {
    @get:Rule val compose = createEmptyComposeRule()
    private fun run(dismiss: Boolean, status: Int) {
        val app = ApplicationProvider.getApplicationContext<MagpieTestApplication>()
        val endpoint = UploadEndpoint().apply { this.status = status }
        val dir = File(app.filesDir, "pdf-inbox").apply { mkdirs() }
        val id = UUID.randomUUID().toString()
        val meta = File(dir, "$id.json")
        val data = File(dir, "$id.pdf")
        data.writeText("%PDF-1.7 fixture")
        meta.writeText(JSONObject().put("id", id).put("owner", endpoint.owner).put("filename", "test.pdf").toString())
        val automation = InstrumentationRegistry.getInstrumentation().uiAutomation
        val events = CopyOnWriteArrayList<String>()
        val scenario = ActivityScenario.launch<ShareActivity>(Intent(app, ShareActivity::class.java).setAction(Intent.ACTION_SEND).setType("application/pdf"))
        try {
            val client = PDFClient("https://example.invalid", "test", endpoint::connect)
            scenario.onActivity { activity ->
                activity.setContent { PDFUploadDialog(null, endpoint.owner, client, current = { true }, onClose = activity::finish) }
            }
            compose.waitUntil(10000) { compose.onAllNodesWithText("Retry upload").fetchSemanticsNodes().isNotEmpty() }
            val retry = compose.onNodeWithText("Retry upload")
            if (dismiss) retry.performClick() else retry.performSemanticsAction(SemanticsActions.OnClick) { click -> click(); click() }
            compose.waitUntil(10000) { endpoint.calls.get() >= 1 }
            if (dismiss) {
                compose.onNodeWithText("Done").performClick()
                compose.waitUntil(10000) { scenario.state == Lifecycle.State.DESTROYED }
                automation.setOnAccessibilityEventListener { e ->
                    // Older Android versions can still deliver explicit TalkBack announcements.
                    @Suppress("DEPRECATION")
                    val explicitAnnouncement = e.eventType == AccessibilityEvent.TYPE_ANNOUNCEMENT
                    if (e.packageName == app.packageName && (explicitAnnouncement ||
                        e.text.any { it.toString().contains("fixture upload failed") })) events.add(e.toString())
                }
            }
            endpoint.gate.countDown()
            assertTrue(endpoint.returned.await(10, TimeUnit.SECONDS))
            if (dismiss) {
                automation.waitForIdle(600, 5000)
                assertTrue(events.toString(), events.isEmpty())
                if (status == 202) compose.waitUntil(5000) { !meta.exists() && !data.exists() }
                else assertTrue(meta.exists() && data.exists())
            } else {
                compose.waitUntil(5000) { compose.onAllNodesWithText("fixture upload failed").fetchSemanticsNodes().isNotEmpty() }
            }
            assertEquals(1, endpoint.calls.get())
        } finally {
            endpoint.gate.countDown()
            automation.setOnAccessibilityEventListener(null)
            scenario.close()
            meta.delete()
            data.delete()
        }
    }
    @Test fun acceptedAfterDismissalClearsQueueSilently() = run(true, 202)
    @Test fun failureAfterDismissalRemainsQueuedSilently() = run(true, 503)
    @Test fun twoRetryActionsBeforeRecompositionSendOneRequest() = run(false, 503)
}
