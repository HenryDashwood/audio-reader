package com.henrydashwood.magpie

import androidx.activity.compose.setContent
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Density
import androidx.lifecycle.ViewModelProvider
import androidx.test.platform.app.InstrumentationRegistry
import com.henrydashwood.magpie.ui.MagpieApp
import com.henrydashwood.magpie.ui.MagpieTheme
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createEmptyComposeRule
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import com.henrydashwood.magpie.data.HttpLibraryApi
import com.henrydashwood.magpie.telemetry.*
import kotlinx.coroutines.*
import org.json.JSONObject
import org.junit.*
import org.junit.Assert.*
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.util.UUID
import java.util.concurrent.CopyOnWriteArrayList

class DiagnosticsTest {
    @get:Rule val compose = createEmptyComposeRule()
    private val app get() = ApplicationProvider.getApplicationContext<MagpieTestApplication>()
    private lateinit var directory: File
    private var scenario: ActivityScenario<MainActivity>? = null
    private var watchdog: MainThreadDiagnostics? = null
    private val work = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var originalPreference = true
    private val owner = "a".repeat(64)
    @Before fun setup() {
        directory = File(app.cacheDir, "diagnostics-${UUID.randomUUID()}").apply { mkdirs() }
        originalPreference = app.diagnosticsEnabled.value
        scenario = ActivityScenario.launch(MainActivity::class.java)
    }
    @After fun cleanup() {
        watchdog?.stop(); work.cancel(); scenario?.close()
        app.setDiagnosticsEnabled(originalPreference); directory.deleteRecursively()
    }
    private class Connection(url: URL, val status: Int = 204) : HttpURLConnection(url) {
        val body = ByteArrayOutputStream()
        override fun getOutputStream() = body
        override fun getResponseCode() = status
        override fun getInputStream() = ByteArrayInputStream(byteArrayOf())
        override fun getErrorStream() = ByteArrayInputStream(byteArrayOf())
        override fun connect() = Unit
        override fun disconnect() = Unit
        override fun usingProxy() = false
    }
    @Test fun telemetryUsesTheExistingAuthenticatedContractWithoutFollowingRedirects() = runBlocking {
        val connections = mutableListOf<Connection>()
        var status = 204; var rejected: String? = null
        val api = HttpLibraryApi("https://diagnostics.invalid", { rejected = it }) { url -> Connection(url, status).also { connections += it } }
        val trace = telemetryTrace("original-request")
        api.reportTelemetry("test-token", TelemetryEvent("voice", mapOf("outcome" to "error", "command_sent" to false), trace))
        val sent = connections.single()
        assertEquals("/events/voice", sent.url.path)
        assertEquals("Bearer test-token", sent.getRequestProperty("Authorization"))
        assertEquals(trace, sent.getRequestProperty("traceparent"))
        assertEquals(setOf("outcome", "command_sent"), JSONObject(sent.body.toString()).keys().asSequence().toSet())
        assertFalse(sent.instanceFollowRedirects)
        status = 302
        assertTrue(runCatching { api.reportTelemetry("test-token", TelemetryEvent("diagnostic", mapOf("kind" to "crash"))) }.isFailure)
        assertEquals(2, connections.size)
        status = 401
        assertTrue(runCatching { api.reportTelemetry("expired-token", TelemetryEvent("voice", mapOf("outcome" to "error"))) }.isFailure)
        assertEquals("expired-token", rejected)
    }
    @Test fun diskQueueAndCrashMarkerSurviveRecreationAndClearTogether() = runBlocking {
        val store = FileTelemetryStore(directory)
        val event = TelemetryEvent("voice", mapOf("outcome" to "spoken", "total_seconds" to 2.5), telemetryTrace("request"))
        val snapshot = TelemetrySnapshot(listOf(event), listOf("previous-event"))
        store.write(owner, snapshot)
        assertEquals(snapshot, FileTelemetryStore(directory).read(owner))
        assertTrue(FileTelemetryStore(directory).read("b".repeat(64)).pending.isEmpty())
        val marker = ExitMarker(UUID.randomUUID().toString(), owner, "private-hash", "version", "Android", 10)
        val file = File(directory, "exit-marker.json")
        FileExitMarkerStore(file).write(marker)
        assertEquals(marker, FileExitMarkerStore(file).read())
        store.clear()
        assertFalse(directory.exists())
    }
    @Test fun settingsOptOutSurvivesActivityRecreationAndDoesNotChangePlaybackControls() {
        compose.onNodeWithText("Settings").performClick()
        compose.onNodeWithTag("settings-list").performScrollToNode(hasContentDescription("Share app diagnostics"))
        val toggle = compose.onNodeWithContentDescription("Share app diagnostics")
        if (app.diagnosticsEnabled.value) toggle.performClick()
        toggle.assertIsOff()
        scenario!!.recreate()
        compose.onNodeWithTag("settings-list").performScrollToNode(hasContentDescription("Share app diagnostics"))
        compose.onNodeWithContentDescription("Share app diagnostics").assertIsOff()
        compose.onNodeWithContentDescription("Share app diagnostics").performClick()
        compose.onNodeWithContentDescription("Share app diagnostics").assertIsOn()
    }
    @Test fun diagnosticsControlRemainsReadableWithLargeTextAndDarkMode() {
        scenario!!.onActivity { activity ->
            val model = ViewModelProvider(activity)[MagpieModel::class.java]
            activity.setContent {
                CompositionLocalProvider(LocalDensity provides Density(activity.resources.displayMetrics.density, 2f)) {
                    MagpieTheme(darkTheme = true) { MagpieApp(model) }
                }
            }
        }
        compose.onNodeWithText("Settings").performClick()
        compose.onNodeWithTag("settings-list").performScrollToNode(hasContentDescription("Share app diagnostics"))
        compose.onNodeWithContentDescription("Share app diagnostics").assertIsDisplayed()
        compose.onNodeWithText("Send voice-request outcomes and crash or freeze summaries. Never your words or audio.").performScrollTo().assertIsDisplayed()
        compose.onNodeWithContentDescription("Share app diagnostics").assertIsDisplayed()
        val bitmap = checkNotNull(InstrumentationRegistry.getInstrumentation().uiAutomation.takeScreenshot())
        val output = InstrumentationRegistry.getArguments().getString("additionalTestOutputDir")?.let(::File) ?: directory
        output.mkdirs()
        File(output, "diagnostics-large-dark.png").outputStream().use { bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it) }
    }
    @Test fun aRecoveredForegroundFreezeProducesOneSummaryWithoutAnyStackOrContent() {
        val events = CopyOnWriteArrayList<TelemetryEvent>()
        val session = TelemetryScope(owner, 1, "private-hash")
        val queue = TelemetryQueue(FileTelemetryStore(directory), { session }, { _, event -> events += event }, work)
        watchdog = MainThreadDiagnostics(app, queue, { session }, work, "fixture", "Android fixture", { app.foregroundVisible })
        watchdog!!.updateSession(); watchdog!!.start()
        // This isolated test application deliberately stalls its main thread,
        // exercising the real acknowledgement path, not a fabricated crash payload.
        scenario!!.onActivity { Thread.sleep(6_500) }
        compose.waitUntil(10_000) { events.isNotEmpty() }
        val event = events.single()
        assertEquals("hang", event.fields["kind"])
        assertEquals("android_main_thread_unresponsive", event.fields["termination_reason"])
        assertTrue((event.fields["hang_seconds"] as Double) >= 5)
        assertEquals(setOf("kind", "termination_reason", "hang_seconds", "app_version", "os_version", "window_end"), event.fields.keys)
    }
}
