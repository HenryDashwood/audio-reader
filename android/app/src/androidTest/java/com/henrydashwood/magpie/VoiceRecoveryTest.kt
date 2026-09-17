package com.henrydashwood.magpie

import android.content.Intent
import androidx.activity.compose.setContent
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Density
import com.henrydashwood.magpie.ui.MagpieApp
import com.henrydashwood.magpie.ui.MagpieTheme
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.lifecycle.ViewModelProvider
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import com.henrydashwood.magpie.data.*
import com.henrydashwood.magpie.playback.PlaybackService
import com.henrydashwood.magpie.voice.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.flow
import org.junit.*
import org.junit.Assert.*
import java.io.File
import java.util.UUID

class VoiceRecoveryTest {
    @get:Rule val compose = createEmptyComposeRule()
    private val app get() = ApplicationProvider.getApplicationContext<MagpieTestApplication>()
    private lateinit var directory: File
    private lateinit var api: Api
    private lateinit var library: AccountLibrary
    private lateinit var model: MagpieModel
    private lateinit var first: VoiceRequest
    private lateinit var second: VoiceRequest
    private lateinit var queue: PodcastProgressQueue
    private var scenario: ActivityScenario<MainActivity>? = null
    private val said = mutableListOf<String>()
    private class Api : LibraryApi, DiscoveryApi, VoiceApi, PodcastProgressApi, LibraryActionApi {
        val typedRequests = mutableListOf<Triple<String, Int?, String>>()
        val typedCancellations = mutableListOf<String>()
        override suspend fun libraryAction(token: String, action: String, episodeId: Int?, requestId: String): VoiceResponse {
            typedRequests += Triple(action, episodeId, requestId)
            return if (action == "undo") VoiceResponse(VoiceAction.Unknown, "There is no recent action to undo.")
            else VoiceResponse(VoiceAction.decode(action), "Updated the original item.", podcast.copy(id = checkNotNull(episodeId), completed = action == "mark_played"))
        }
        override suspend fun cancelLibraryAction(token: String, requestId: String) { typedCancellations += "$token:$requestId" }
        var allowed = true
        var grants = 0
        var filed = false
        var secondFiled = false
        var articleFiled = false
        val writesAfterFiling = mutableListOf<Boolean>()
        val requests = mutableListOf<VoiceRequest>()
        val cancellations = mutableListOf<String>()
        var gate: CompletableDeferred<Unit>? = null
        val podcast = RemoteEpisode(1, "First fixture podcast", source = "Fixture show", audioUrl = "asset:///welcome.wav", positionSeconds = 12.0, progressRevision = "c".repeat(64))
        val second = podcast.copy(id = 2, title = "Second fixture podcast", positionSeconds = 0.0)
        val article = RemoteEpisode(3, "Fixture reading", contentId = 88, wordCount = 100)
        var response = VoiceResponse(VoiceAction.Unknown, "Which show would you like?", expectsReply = true)
        override suspend fun podcastProgress(token: String, episodeId: Int, report: PodcastProgressReport): PodcastProgressReceipt {
            throw com.henrydashwood.magpie.auth.AccountFailure(409, "Changed")
        }
        override suspend fun episode(token: String, episodeId: Int) = podcast.copy(completed = filed)
        override suspend fun userId(token: String) = "user-$token"
        override suspend fun feeds(token: String) = listOf(LibraryFeed("10", "Fixture show", 2, false))
        override suspend fun latest(token: String) = listOfNotNull(podcast.takeUnless { filed }, second.takeUnless { secondFiled }, article.takeUnless { articleFiled })
        override suspend fun saved(token: String) = emptyList<RemoteEpisode>()
        override suspend fun episodes(token: String, feedId: String, query: String) = latest(token)
        override suspend fun search(token: String, query: String) = latest(token)
        override suspend fun text(token: String, episodeId: Int, contentId: Int?): RemoteText {
            val paragraphs = (1..5).joinToString("\n\n") { "Paragraph $it describes a quiet morning walk through the garden. The trees are full of birds, and there is time to listen before continuing with the day." }
            return RemoteText(episodeId, 88, paragraphs, null, 145)
        }
        override suspend fun save(token: String, episodeId: Int?, url: String?) = podcast
        override suspend fun remove(token: String, episodeId: Int) {}
        override suspend fun played(token: String, episodeId: Int, played: Boolean) {}
        override suspend fun clearLatest(token: String) {}
        override suspend fun subscribe(token: String, url: String) = feeds(token).first()
        override suspend fun position(token: String, episodeId: Int, seconds: Double, completed: Boolean) {
            assertNotEquals("Rendered article seconds must never be uploaded", 3, episodeId)
            if (filed) writesAfterFiling += completed
        }
        override suspend fun directory(token: String, query: String) = emptyList<SourceResult>()
        override suspend fun discover(token: String, url: String) = emptyList<SourceResult>()
        override suspend fun preview(token: String, url: String) = RemotePreview(feeds(token).first(), latest(token), true)
        override suspend fun webSearch(token: String, query: String): SourceResult? = null
        override suspend fun aiConsent(token: String) = allowed
        override suspend fun setAIConsent(token: String, granted: Boolean): Boolean { grants++; allowed = granted; return allowed }
        override fun events(token: String, request: VoiceRequest) = flow {
            requests += request; emit(VoiceEvent.Delta("Working…")); gate?.await()
            response.effects.forEach { effect ->
                if (effect.action in setOf(VoiceAction.Played, VoiceAction.Restore)) {
                    if (effect.episode?.id == 1) filed = effect.action == VoiceAction.Played
                    if (effect.episode?.id == 2) secondFiled = effect.action == VoiceAction.Played
                    if (effect.episode?.id == 3) articleFiled = effect.action == VoiceAction.Played
                }
            }
            emit(VoiceEvent.Result(response))
        }
        override suspend fun cancel(token: String, requestId: String) { cancellations += "$token:$requestId" }
    }
    @Before fun setup() {
        app.stopService(Intent(app, PlaybackService::class.java))
        directory = File(app.noBackupFilesDir, "voice-recovery-test-${UUID.randomUUID()}")
        api = Api()
        queue = PodcastProgressQueue(FilePodcastProgressStore(File(directory, "progress")))
        val original = AccountLibrary(api, "https://recovery.invalid", progressQueue = queue,
            conversationStore = FileConversationStore(directory))
        runBlocking(Dispatchers.Main) {
            original.changeSession("one")
            val owner = original.state.value.owner!!
            val conversation = original.voiceConversation
            conversation.activate("old-session"); conversation.restore(owner)
            first = conversation.request("File the original episode", 1, 1, "GB")
            conversation.confirmed(first, conversation.owner,
                VoiceResponse(VoiceAction.Played, "Marked it played.", api.podcast.copy(completed = true)))
            conversation.persist(owner)
            second = conversation.request("Find history", 1, 2, "GB"); conversation.persist(owner)
            queue.start(owner, 1, "old-playback", "a".repeat(64), ProgressSample(10.0), false)
            queue.record(owner, 1, "old-playback", ProgressSample(20.0))
            queue.hold(owner, setOf(1), first.requestId)
        }
        // New repository, conversation and file-store objects stand in for a fresh process.
        library = AccountLibrary(api, "https://recovery.invalid", progressQueue = queue,
            conversationStore = FileConversationStore(directory))
        runBlocking(Dispatchers.Main) { library.changeSession("one") }
        app.libraryOverride = library
        app.voiceOutputOverride = VoiceOutput { said += it }
        app.voiceInputOverride = object : VoiceInput {
            override suspend fun availability() = RecognitionAvailability.Ready
            override suspend fun listen(firstWordsMs: Long, onReady: () -> Unit, onPartial: (String) -> Unit): String? = error("Recovery must not open the microphone")
            override fun finish() {}
        }
        scenario = ActivityScenario.launch(MainActivity::class.java)
        scenario!!.onActivity { model = ViewModelProvider(it)[MagpieModel::class.java] }
        compose.waitUntil(10_000) { model.player.value.connected }
        compose.onNodeWithContentDescription("Ask Magpie").performClick()
        compose.waitUntil(10_000) { model.voice.state.value.recoveryRequests.size == 2 }
    }
    @After fun cleanup() {
        compose.runOnUiThread { model.voice.close(false) }
        scenario?.close(); app.stopService(Intent(app, PlaybackService::class.java))
        app.libraryOverride = null; app.voiceOutputOverride = null; app.voiceInputOverride = null
        directory.deleteRecursively()
    }
    @Test fun checkOlderReceiptPreservesNewerFilingAndReleasesItsDurableProgressGuard() {
        assertTrue(api.requests.isEmpty())
        compose.onNodeWithTag("conversation-history").performScrollToNode(hasContentDescription("Check request: ${first.transcript}"))
        compose.onNodeWithContentDescription("Check request: ${first.transcript}").performClick()
        compose.waitUntil(10_000) { !model.voice.state.value.busy && model.voice.state.value.recoveryRequests.size == 1 }
        assertTrue(api.requests.isEmpty()); assertFalse(library.state.value.items.first { it.episodeId == 1 }.completed)
        assertFalse(model.player.value.playing); assertTrue(said.single().startsWith("Earlier result:"))
        val owner = library.state.value.owner!!
        assertTrue(runBlocking { queue.entries(owner).single().guards.isEmpty() })
        runBlocking(Dispatchers.Main) { library.flushPodcastProgress() }
        assertTrue(runBlocking { queue.entries(owner).single().blocked })
        assertEquals(second, runBlocking { FileConversationStore(directory).read(owner).single().request })
    }
    @Test fun unknownOutcomeUsesExactOriginalRequestAndSignoutClearsRemainingPrivateRecovery() {
        compose.onNodeWithTag("conversation-history").performScrollToNode(hasContentDescription("Check request: ${second.transcript}"))
        compose.onNodeWithContentDescription("Check request: ${second.transcript}").performClick()
        compose.waitUntil(10_000) { !model.voice.state.value.busy && api.requests.size == 1 }
        assertEquals(second, api.requests.single())
        val owner = library.state.value.owner!!
        assertEquals(first, runBlocking { FileConversationStore(directory).read(owner).single().request })
        runBlocking(Dispatchers.Main) { library.changeSession(null) }
        compose.waitUntil(10_000) { model.voice.state.value.recoveryRequests.isEmpty() }
        assertTrue(runBlocking { FileConversationStore(directory).read(owner).isEmpty() })
    }
    @Test fun dismissalRequiresConfirmationAndCancelsOnlyTheSelectedOriginalRequest() {
        api.allowed = false
        fun openDismiss() {
            compose.onNodeWithTag("conversation-history").performScrollToNode(hasContentDescription("Dismiss request: ${first.transcript}"))
            compose.onNodeWithContentDescription("Dismiss request: ${first.transcript}").performClick()
        }
        openDismiss(); compose.onNodeWithText("Keep request").performClick()
        assertTrue(api.cancellations.isEmpty())
        openDismiss(); compose.onNode(hasText("Dismiss request") and hasAnyAncestor(isDialog() and hasAnyDescendant(hasText("Stop checking this request?")))).performClick()
        compose.waitUntil(10_000) { !model.voice.state.value.busy && model.voice.state.value.recoveryRequests.size == 1 }
        assertEquals(listOf("one:${first.requestId}"), api.cancellations)
        assertTrue(api.requests.isEmpty()); assertEquals(0, api.grants)
        val owner = library.state.value.owner!!
        assertEquals(second, runBlocking { FileConversationStore(directory).read(owner).single().request })
        assertTrue(runBlocking { queue.entries(owner).single().guards.isEmpty() })
    }

    private fun replaceRecovery(entries: List<RecoverableVoiceRequest>) {
        compose.runOnUiThread { model.voice.close(false) }
        val owner = library.state.value.owner!!
        runBlocking { FileConversationStore(directory).write(owner, entries) }
        compose.runOnUiThread {
            library.voiceConversation.activate(null)
            library.voiceConversation.activate("${library.state.value.revision}:$owner:true")
            model.voice.open(null)
        }
        compose.waitUntil(10_000) { model.voice.state.value.recoveryRequests == entries.asReversed().map { it.request } }
    }
    @Test fun typedRecoveryUsesOriginalRouteAndTargetWithoutAIThenDismissesOnlyOriginalUndo() {
        api.allowed = false
        val filing = VoiceRequest("Mark as played: First fixture podcast", "typed-original-filing")
        val undo = VoiceRequest("Undo the last library change", "typed-original-undo")
        replaceRecovery(listOf(RecoverableVoiceRequest(filing, structured = StructuredLibraryRequest("mark_played", 1, true)),
            RecoverableVoiceRequest(undo, structured = StructuredLibraryRequest("undo", null))))
        compose.onNodeWithTag("conversation-history").performScrollToNode(hasContentDescription("Check request: ${filing.transcript}"))
        compose.onNodeWithContentDescription("Check request: ${filing.transcript}").performClick()
        compose.waitUntil(10_000) { !model.voice.state.value.busy && model.voice.state.value.recoveryRequests.size == 1 }
        assertEquals(listOf(Triple("mark_played", 1, filing.requestId)), api.typedRequests)
        assertTrue(api.requests.isEmpty()); assertEquals(0, api.grants)
        assertFalse(library.state.value.items.first { it.episodeId == 1 }.completed)
        compose.onNodeWithTag("conversation-history").performScrollToNode(hasContentDescription("Dismiss request: ${undo.transcript}"))
        compose.onNodeWithContentDescription("Dismiss request: ${undo.transcript}").performClick()
        compose.onNode(hasText("Dismiss request") and hasAnyAncestor(isDialog() and hasAnyDescendant(hasText("Stop checking this request?")))).performClick()
        compose.waitUntil(10_000) { !model.voice.state.value.busy && model.voice.state.value.recoveryRequests.isEmpty() }
        assertEquals(listOf("one:${undo.requestId}"), api.typedCancellations)
        assertTrue(api.cancellations.isEmpty()); assertTrue(api.requests.isEmpty())
    }
    @Test fun askUndoWorksWithoutAIAndItsStoredReceiptDoesNotRunUndoAgain() {
        api.allowed = false
        val undo = VoiceRequest("Undo the last library change", "saved-undo-receipt")
        replaceRecovery(listOf(RecoverableVoiceRequest(undo,
            VoiceResponse(VoiceAction.Restore, "Restored the first podcast.", api.podcast), StructuredLibraryRequest("undo", null))))
        compose.onNodeWithTag("conversation-history").performScrollToNode(hasContentDescription("Check request: ${undo.transcript}"))
        compose.onNodeWithContentDescription("Check request: ${undo.transcript}").performClick()
        compose.waitUntil(10_000) { !model.voice.state.value.busy && model.voice.state.value.recoveryRequests.isEmpty() }
        assertTrue(api.typedRequests.isEmpty())
        compose.runOnUiThread { model.voice.submit("undo") }
        compose.waitUntil(10_000) { !model.voice.state.value.busy && api.typedRequests.size == 1 }
        assertEquals("undo", api.typedRequests.single().first); assertNull(api.typedRequests.single().second)
        assertNotEquals(undo.requestId, api.typedRequests.single().third)
        assertTrue(api.requests.isEmpty()); assertEquals(0, api.grants)
    }

    @Test fun recoveryChoicesAndDismissalStayReachableAtLargeTextInDarkMode() {
        scenario!!.onActivity { activity -> activity.setContent {
            CompositionLocalProvider(LocalDensity provides Density(LocalDensity.current.density, 2f)) {
                MagpieTheme(darkTheme = true) { MagpieApp(model) }
            }
        } }
        compose.onNodeWithTag("conversation-history").performScrollToNode(hasContentDescription("Check request: ${first.transcript}"))
        compose.onNodeWithContentDescription("Check request: ${first.transcript}").assertIsDisplayed()
        compose.onNodeWithText("Close").assertIsDisplayed()
        val instrumentation = androidx.test.platform.app.InstrumentationRegistry.getInstrumentation()
        val directory = androidx.test.platform.app.InstrumentationRegistry.getArguments().getString("additionalTestOutputDir") ?: app.filesDir.path
        val screenshot = checkNotNull(instrumentation.uiAutomation.takeScreenshot())
        File(directory, "voice-recovery-large-dark.png").outputStream().use { screenshot.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it) }
        screenshot.recycle()
        compose.onNodeWithTag("conversation-history").performScrollToNode(hasContentDescription("Dismiss request: ${first.transcript}"))
        compose.onNodeWithContentDescription("Dismiss request: ${first.transcript}").assertIsDisplayed().performClick()
        compose.onNodeWithText("Keep request").assertIsDisplayed().performClick()
        assertTrue(api.requests.isEmpty()); assertTrue(api.cancellations.isEmpty())
    }

}
