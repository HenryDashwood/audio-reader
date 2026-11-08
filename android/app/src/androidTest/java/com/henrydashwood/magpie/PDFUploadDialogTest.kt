package com.henrydashwood.magpie

import android.content.Intent
import android.view.accessibility.AccessibilityEvent
import androidx.activity.compose.setContent
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.test.junit4.StateRestorationTester
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createEmptyComposeRule
import androidx.lifecycle.Lifecycle
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import androidx.test.platform.app.InstrumentationRegistry
import com.henrydashwood.magpie.data.PDFClient
import com.henrydashwood.magpie.ui.PDFUploadDialog
import com.henrydashwood.magpie.ui.AccountPDFImportDialog
import com.henrydashwood.magpie.sharing.articlePdfDestination
import com.henrydashwood.magpie.sharing.articlePdfUri
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
    val accessCalls = AtomicInteger()
    var failFirstCheck = false
    fun connect(url: URL): HttpURLConnection = object : HttpURLConnection(url) {
        override fun connect() {}
        override fun disconnect() { if (url.path.endsWith("/file")) returned.countDown() }
        override fun usingProxy() = false
        override fun getOutputStream() = ByteArrayOutputStream()
        override fun getResponseCode(): Int {
            if (!url.path.endsWith("/file")) return if (accessCalls.incrementAndGet() == 1 && failFirstCheck) 503 else 200
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
    @Test fun removeTapQueuedBeforeAccountSwitchPreservesTheOriginalFile() {
        val app = ApplicationProvider.getApplicationContext<MagpieTestApplication>()
        val endpoint = UploadEndpoint()
        val dir = File(app.filesDir, "pdf-inbox").apply { mkdirs() }
        val id = UUID.randomUUID().toString()
        val meta = File(dir, "$id.json")
        val data = File(dir, "$id.pdf")
        data.writeText("%PDF-1.7 fixture")
        meta.writeText(JSONObject().put("id", id).put("owner", endpoint.owner).put("filename", "original.pdf").toString())
        val intent = Intent(app, ShareActivity::class.java).setAction(Intent.ACTION_SEND).setType("application/pdf")
        try {
            ActivityScenario.launch<ShareActivity>(intent).use { scenario ->
                var signedInAsOriginal = true
                val checkedAfterSwitch = CountDownLatch(1)
                val client = PDFClient("https://example.invalid", "test", endpoint::connect)
                scenario.onActivity { activity ->
                    activity.setContent {
                        PDFUploadDialog(null, endpoint.owner, client, current = {
                            if (!signedInAsOriginal) checkedAfterSwitch.countDown()
                            signedInAsOriginal
                        }, onClose = activity::finish)
                    }
                }
                compose.waitUntil(10000) { compose.onAllNodesWithText("Remove local PDF").fetchSemanticsNodes().isNotEmpty() }
                val remove = compose.onNodeWithText("Remove local PDF")
                remove.performSemanticsAction(SemanticsActions.OnClick) { click ->
                    signedInAsOriginal = false
                    click()
                }
                compose.waitUntil(5000) { checkedAfterSwitch.count == 0L }
                assertTrue(meta.exists())
                assertEquals("%PDF-1.7 fixture", data.readText())
                remove.performSemanticsAction(SemanticsActions.OnClick) { click ->
                    signedInAsOriginal = true
                    click()
                }
                compose.waitUntil(5000) { !meta.exists() && !data.exists() }
                assertEquals(0, endpoint.calls.get())
            }
        } finally {
            meta.delete()
            data.delete()
        }
    }

    @Test fun checkingAccessAfterAServiceFailureEnablesFileSelection() {
        val app = ApplicationProvider.getApplicationContext<MagpieTestApplication>()
        val endpoint = UploadEndpoint().apply { failFirstCheck = true }
        val intent = Intent(app, ShareActivity::class.java).setAction(Intent.ACTION_SEND).setType("application/pdf")
        ActivityScenario.launch<ShareActivity>(intent).use { scenario ->
            val client = PDFClient("https://example.invalid", "test", endpoint::connect)
            scenario.onActivity { activity ->
                activity.setContent { PDFUploadDialog(null, endpoint.owner, client, current = { true }, onClose = activity::finish) }
            }
            compose.waitUntil(10000) { compose.onAllNodesWithText("Check access").fetchSemanticsNodes().isNotEmpty() }
            compose.onNodeWithText("Choose PDF").assertDoesNotExist()
            compose.onNodeWithText("Check access").performClick()
            compose.waitUntil(10000) { compose.onAllNodesWithText("Choose PDF").fetchSemanticsNodes().isNotEmpty() }
            compose.onNodeWithText("Check access").assertDoesNotExist()
            assertEquals(2, endpoint.accessCalls.get())
            assertEquals(0, endpoint.calls.get())
        }
    }

    @Test fun acceptedAfterDismissalClearsQueueSilently() = run(true, 202)
    @Test fun failureAfterDismissalRemainsQueuedSilently() = run(true, 503)
    @Test fun twoRetryActionsBeforeRecompositionSendOneRequest() = run(false, 503)
}

class SharedPDFAccountTest {
    @get:Rule val compose = createComposeRule()

    @Test fun sharedAttachmentDoesNotFollowAnAccountSwitchOrRecreation() {
        val app = ApplicationProvider.getApplicationContext<MagpieTestApplication>()
        val first = UploadEndpoint()
        val second = UploadEndpoint().apply { gate.countDown() }
        val firstClient = PDFClient("https://example.invalid", "first", first::connect)
        val secondClient = PDFClient("https://example.invalid", "second", second::connect)
        val file = articlePdfDestination(app, "Shared report")
        file.writeText("%PDF-1.7 fixture")
        val uri = articlePdfUri(app, file)
        val account = mutableStateOf(first.owner)
        val delivery = mutableStateOf(0)
        val restored = StateRestorationTester(compose)
        try {
            restored.setContent {
                val owner = account.value
                key(delivery.value) {
                    AccountPDFImportDialog(uri, owner, if (owner == first.owner) firstClient else secondClient,
                        current = { owner == account.value }, onClose = {})
                }
            }
            fun awaitControl(text: String) = compose.waitUntil(10000) {
                compose.onAllNodesWithText(text).fetchSemanticsNodes().isNotEmpty()
            }
            awaitControl("Save selected PDF")
            compose.runOnIdle { account.value = second.owner }
            awaitControl("Choose PDF")
            compose.onNodeWithText("Save selected PDF").assertDoesNotExist()
            restored.emulateSavedInstanceStateRestore()
            awaitControl("Choose PDF")
            compose.onNodeWithText("Save selected PDF").assertDoesNotExist()
            assertEquals(0, first.calls.get())
            assertEquals(0, second.calls.get())

            // Sharing even the same URI again is an explicit new delivery for the second account.
            compose.runOnIdle { delivery.value++ }
            awaitControl("Save selected PDF")
            compose.onNodeWithText("Save selected PDF").performClick()
            compose.waitUntil(10000) { second.returned.count == 0L }
            assertEquals(1, second.calls.get())
            assertEquals(0, first.calls.get())
        } finally {
            file.delete()
            file.parentFile?.delete()
        }
    }
}
