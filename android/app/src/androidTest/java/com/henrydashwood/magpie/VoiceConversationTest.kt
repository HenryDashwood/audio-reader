package com.henrydashwood.magpie

import android.Manifest
import android.content.ComponentName
import android.content.Intent
import android.os.Bundle
import androidx.activity.compose.setContent
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Density
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.lifecycle.ViewModelProvider
import androidx.media3.session.MediaController
import androidx.media3.session.SessionCommand
import androidx.media3.session.SessionToken
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import androidx.test.platform.app.InstrumentationRegistry
import com.henrydashwood.magpie.data.*
import com.henrydashwood.magpie.playback.PlaybackService
import com.henrydashwood.magpie.playback.PlaybackStatus
import com.henrydashwood.magpie.ui.MagpieApp
import com.henrydashwood.magpie.ui.MagpieTheme
import com.henrydashwood.magpie.voice.*
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.flow
import org.junit.*
import org.junit.Assert.*
import java.io.File
import java.util.concurrent.TimeUnit

class VoiceConversationTest {
    @get:Rule val compose = createEmptyComposeRule()
    private val app get() = ApplicationProvider.getApplicationContext<MagpieTestApplication>()
    private lateinit var api: Api
    private lateinit var library: AccountLibrary
    private lateinit var input: Input
    private lateinit var output: Output
    private lateinit var model: MagpieModel
    private lateinit var previous: ListeningSettings
    private lateinit var previousConversation: ConversationPreferences
    private var scenario: ActivityScenario<MainActivity>? = null
    private class Input : VoiceInput {
        val words = Channel<String?>(Channel.UNLIMITED)
        val waits = mutableListOf<Long>()
        var active = false
        override suspend fun listen(firstWordsMs: Long, onReady: () -> Unit, onPartial: (String) -> Unit): String? {
            active = true; waits += firstWordsMs
            try { onReady(); return words.receive() } finally { active = false }
        }
        override fun finish() { words.trySend(null) }
    }
    private class Output : VoiceOutput {
        var gate: CompletableDeferred<Unit>? = null
        var delegate: VoiceOutput? = null
        val said = mutableListOf<String>()
        override suspend fun speak(text: String) { said += text; gate?.await(); delegate?.speak(text) }
    }
    private class Api : LibraryApi, DiscoveryApi, VoiceApi {
        var allowed = true
        var grants = 0
        var filed = false
        var secondFiled = false
        var articleFiled = false
        val writesAfterFiling = mutableListOf<Boolean>()
        val requests = mutableListOf<VoiceRequest>()
        val cancellations = mutableListOf<String>()
        var gate: CompletableDeferred<Unit>? = null
        val podcast = RemoteEpisode(1, "First fixture podcast", source = "Fixture show", audioUrl = "asset:///welcome.wav", positionSeconds = 12.0)
        val second = podcast.copy(id = 2, title = "Second fixture podcast", positionSeconds = 0.0)
        val article = RemoteEpisode(3, "Fixture reading", contentId = 88, wordCount = 100)
        var response = VoiceResponse(VoiceAction.Unknown, "Which show would you like?", expectsReply = true)
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
    @Before fun prepare() {
        InstrumentationRegistry.getInstrumentation().uiAutomation.grantRuntimePermission(app.packageName, Manifest.permission.RECORD_AUDIO)
        app.stopService(Intent(app, PlaybackService::class.java))
        api = Api(); input = Input(); output = Output()
        library = AccountLibrary(api, "https://voice-fixture.invalid")
        runBlocking(Dispatchers.Main) { library.changeSession("one") }
        app.libraryOverride = library; app.voiceInputOverride = input; app.voiceOutputOverride = output
        scenario = ActivityScenario.launch(MainActivity::class.java)
        scenario!!.onActivity { model = ViewModelProvider(it)[MagpieModel::class.java] }
        previous = model.settings.value; previousConversation = model.conversationSettings.value
        compose.runOnUiThread { model.setConversationPreferences(ConversationPreferences(false)); model.setSpeed(ContentKind.Podcast, 1f) }
        compose.waitUntil(10_000) { model.player.value.connected }
    }
    @After fun finish() {
        compose.runOnUiThread {
            model.voice.close(false); model.pause()
            model.setSpeed(ContentKind.Podcast, previous.podcastSpeed); model.setSpeed(ContentKind.Article, previous.articleSpeed)
            model.setConversationPreferences(previousConversation)
        }
        scenario?.close(); app.stopService(Intent(app, PlaybackService::class.java))
        app.libraryOverride = null; app.voiceInputOverride = null; app.voiceOutputOverride = null
    }
    private fun play() {
        compose.runOnUiThread { model.play(model.library.first { it.episodeId == 1 }) }
        compose.waitUntil(15_000) { model.player.value.playing }
    }
    private fun ask(text: String) {
        if (!model.voice.state.value.visible) compose.onNodeWithContentDescription("Ask Magpie").performClick()
        compose.onNodeWithText("Type a request").performTextInput(text)
        compose.onNodeWithText("Send").performClick()
    }
    private fun idle() { compose.waitUntil(10_000) { !model.voice.state.value.busy } }

    @Test fun confirmationFinishesBeforeNewPlaybackAndInterruptedReplyCanRecover() {
        play(); output.gate = CompletableDeferred(); api.response = VoiceResponse(VoiceAction.Play, "Playing the second podcast.", api.second)
        ask("Play the second podcast")
        compose.waitUntil(10_000) { model.voice.state.value.phase == VoicePhase.Speaking && !model.player.value.playing }
        assertEquals(1, model.player.value.item?.episodeId)
        val request = api.requests.single()
        compose.onNodeWithText("Close").performClick()
        compose.waitUntil(5_000) { model.player.value.playing }; assertEquals(1, model.player.value.item?.episodeId)
        output.gate = null
        compose.onNodeWithContentDescription("Ask Magpie").performClick()
        compose.onNodeWithText("Check previous request").performClick()
        compose.waitUntil(10_000) { model.player.value.item?.episodeId == 2 && model.player.value.playing }
        assertEquals(request, api.requests.last()); assertFalse(model.voice.state.value.visible)
    }

    @Test fun declinedAIRequestIsNeverSentAndLocalPauseStillWorks() {
        play(); api.allowed = false
        ask("Find a new show")
        compose.onNodeWithText("Use AI for voice and web search?").assertIsDisplayed()
        assertTrue(api.requests.isEmpty()); assertEquals(0, api.grants)
        compose.onNodeWithText("Not now").performClick()
        ask("Pause"); idle()
        compose.waitUntil(5_000) { !model.player.value.playing && !model.voice.state.value.visible }
        assertTrue(api.requests.isEmpty())
    }

    @Test fun explicitConsentAndViewedEpisodeReachTheExistingRequestContract() {
        api.allowed = false
        compose.onNodeWithText("Latest").performClick()
        compose.onNode(hasText(api.podcast.title) and !hasTestTag("mini-player-open")).performClick()
        ask("What is this about?")
        compose.onNodeWithText("Allow AI data sharing").performClick(); idle()
        assertEquals(1, api.grants); assertEquals(1, api.requests.single().viewedEpisodeId)
        assertEquals("What is this about?", api.requests.single().transcript)
        assertEquals(1, model.voice.state.value.turns.count { it.speaker == "her" })
    }

    @Test fun explicitPauseFromAnotherControlStopsCaptureAndPreventsResume() {
        play(); compose.onNodeWithContentDescription("Ask Magpie").performClick()
        compose.onNodeWithText("Listen", substring = false).performClick()
        compose.waitUntil(5_000) { input.active && !model.player.value.playing }
        compose.runOnUiThread { model.pause() }
        compose.waitUntil(5_000) { !input.active && !model.voice.state.value.visible }
        assertFalse(model.player.value.playing); assertNull(PlaybackStatus.voiceToken.value)
    }

    @Test fun localSpeedUndoAndSleepTimerUseTheServiceWithoutTheBackend() {
        play(); ask("Play at 0.5 times speed"); idle()
        assertEquals(.5f, model.settings.value.podcastSpeed)
        ask("Undo that"); idle(); assertEquals(1f, model.settings.value.podcastSpeed)
        ask("Stop in thirty minutes"); idle()
        assertEquals(30, PlaybackStatus.sleepTimer.value.remainingMinutes)
        ask("Cancel sleep timer"); idle(); assertFalse(PlaybackStatus.sleepTimer.value.running)
        assertTrue(api.requests.isEmpty())
        compose.onNodeWithText("Close").performClick()
        compose.waitUntil(5_000) { model.player.value.playing }
    }

    @Test fun filingCurrentEpisodeCannotLaterReportItsOldPositionAsUnplayed() {
        play(); api.response = VoiceResponse(VoiceAction.Played, "Marked as played.", api.podcast.copy(completed = true, positionSeconds = 0.0))
        ask("Mark this episode as played"); idle()
        assertNull("Filing reply: ${model.voice.state.value}", model.voice.state.value.error)
        assertTrue("Filing was not received: ${api.requests}", api.filed)
        try { compose.waitUntil(5_000) { model.player.value.item == null } }
        catch (failure: ComposeTimeoutException) {
            throw AssertionError("Filed item remained loaded: player=${model.player.value}, voice=${model.voice.state.value}, preparation=${PlaybackStatus.state.value}", failure)
        }
        compose.onNodeWithText("Close").performClick()
        assertFalse(model.player.value.playing); assertTrue(api.writesAfterFiling.isEmpty())
        assertTrue(library.state.value.items.first { it.episodeId == 1 }.completed)
    }

    @Test fun cancellingAFilingConfirmationKeepsItFiledAndUndoRestoresThePodcastBookmark() {
        play(); output.gate = CompletableDeferred()
        api.response = VoiceResponse(VoiceAction.Played, "Marked as played.", api.podcast.copy(completed = true, positionSeconds = 0.0))
        ask("Mark this episode as played")
        compose.waitUntil(5_000) { model.voice.state.value.phase == VoicePhase.Speaking && model.player.value.item == null }
        compose.onNodeWithText("Close").performClick()
        assertFalse(model.player.value.playing); assertTrue(api.writesAfterFiling.isEmpty())
        output.gate = null; api.response = VoiceResponse(VoiceAction.Restore, "Restored your episode.", api.podcast)
        ask("Undo that"); idle(); compose.onNodeWithText("Close").performClick()
        play()
        assertTrue(model.player.value.positionMs >= 12_000); assertTrue(model.player.value.positionMs < 20_000)
    }

    @Test fun undoRestoresAnArticlesOwnTextBookmarkWithoutUsingServerAudioSeconds() {
        val item = model.library.first { it.episodeId == 3 }
        compose.runOnUiThread { model.play(item) }
        compose.waitUntil(90_000) { model.player.value.playing || model.preparation.value.error != null }
        assertNull(model.preparation.value.error)
        compose.waitUntil(5_000) { model.player.value.durationMs > 0 }
        val halfway = model.library.first { it.id == item.id }.text.length / 2
        compose.runOnUiThread { model.seek(model.player.value.durationMs * 3 / 4) }
        compose.waitUntil(5_000) { (PlaybackStatus.readingPosition.value?.startUtf16 ?: 0) > halfway }
        compose.runOnUiThread { model.pause() }
        compose.waitUntil(5_000) { !model.player.value.playing }
        val store = PreviewStore(app)
        compose.waitUntil(5_000) { (store.bookmark(item.id)?.offsetUtf16 ?: 0) > halfway }
        val before = checkNotNull(store.bookmark(item.id))
        assertTrue(before.offsetUtf16 > 0)
        api.response = VoiceResponse(VoiceAction.Played, "Marked as read.", api.article.copy(completed = true))
        ask("Mark this article as read"); idle(); assertNull(store.bookmark(item.id))
        api.response = VoiceResponse(VoiceAction.Restore, "Restored your article.", api.article.copy(positionSeconds = 999.0))
        ask("Undo that"); idle()
        assertEquals(before, store.bookmark(item.id))
    }

    @Test fun filingAnotherArticleResetsAndRestoresItsBookmarkWithoutStoppingThePodcast() {
        val item = runBlocking(Dispatchers.Main) { library.content(model.library.first { it.episodeId == 3 }.id) }
        val store = PreviewStore(app)
        val before = com.henrydashwood.magpie.playback.ArticleBookmark(item.contentVersion, 80)
        store.saveBookmark(item.id, before)
        play()
        api.response = VoiceResponse(VoiceAction.Played, "Marked as read.", api.article.copy(completed = true))
        ask("Mark the fixture article as read"); idle()
        assertNull(store.bookmark(item.id))
        compose.waitUntil(5_000) { model.player.value.playing }
        assertEquals(1, model.player.value.item?.episodeId)
        api.response = VoiceResponse(VoiceAction.Restore, "Restored your article.", api.article)
        ask("Undo that"); idle()
        assertEquals(before, store.bookmark(item.id))
        compose.waitUntil(5_000) { model.player.value.playing }
    }

    @Test fun spokenFollowUpWaitsForReplyAudioAndUsesSelectedWaitTime() {
        play(); output.gate = CompletableDeferred()
        compose.runOnUiThread { model.setConversationPreferences(ConversationPreferences(false, 30)); input.words.trySend("Find a show") }
        compose.onNodeWithContentDescription("Ask Magpie").performClick()
        compose.onNodeWithText("Listen").performClick()
        compose.waitUntil(5_000) { model.voice.state.value.phase == VoicePhase.Speaking }
        assertFalse(input.active); assertEquals(listOf(8_000L), input.waits)
        compose.runOnUiThread { output.gate!!.complete(Unit) }
        compose.waitUntil(5_000) { input.active && input.waits.size == 2 }
        assertEquals(30_000L, input.waits.last())
        compose.runOnUiThread { input.words.trySend("That's all") }
        compose.waitUntil(5_000) { !model.voice.state.value.visible && model.player.value.playing }
        assertEquals(1, api.requests.size)
    }

    @Test fun accountChangeDuringRequestClearsConversationAndCancelsOriginalAccount() {
        play(); api.gate = CompletableDeferred(); ask("Find a new podcast")
        compose.waitUntil(5_000) { api.requests.isNotEmpty() }
        val request = api.requests.single()
        runBlocking(Dispatchers.Main) { library.changeSession("two") }
        compose.waitUntil(5_000) { !model.voice.state.value.visible && model.player.value.item == null && api.cancellations.isNotEmpty() }
        assertEquals("one:${request.requestId}", api.cancellations.single())
        compose.runOnUiThread { api.gate!!.complete(Unit) }
        assertFalse(model.voice.state.value.recoverable); assertTrue(model.voice.state.value.turns.isEmpty())
    }

    @Test fun actualOfflineReplyCompletesBeforeInterruptedPodcastResumes() {
        output.delegate = AndroidReplySpeaker(app) { null }
        api.response = VoiceResponse(VoiceAction.Unknown, "You can ask Magpie to find a podcast, read an article, or set a sleep timer. Your podcast will continue when this reply has finished.")
        play(); ask("What can I ask?")
        compose.waitUntil(10_000) { model.voice.state.value.phase == VoicePhase.Speaking }
        assertFalse(model.player.value.playing); assertFalse(input.active)
        compose.waitUntil(45_000) { !model.voice.state.value.busy }
        assertNull(model.voice.state.value.error)
        compose.waitUntil(5_000) { model.player.value.playing }
    }

    @Test fun sleepDeadlineEndsListeningWithoutResumingInterruptedAudio() {
        play()
        val controller = compose.runOnUiThread {
            MediaController.Builder(app, SessionToken(app, ComponentName(app, PlaybackService::class.java))).buildAsync()
        }.get(10, TimeUnit.SECONDS)
        try {
            val result = compose.runOnUiThread {
                controller.sendCustomCommand(SessionCommand(PlaybackService.SET_SLEEP_TIMER, Bundle.EMPTY),
                    Bundle().apply { putLong(PlaybackService.SLEEP_DURATION_MS, 8_000) })
            }.get(10, TimeUnit.SECONDS)
            assertEquals(0, result.resultCode)
            compose.onNodeWithContentDescription("Ask Magpie").performClick(); compose.onNodeWithText("Listen").performClick()
            compose.waitUntil(5_000) { input.active }
            compose.waitUntil(12_000) { !PlaybackStatus.sleepTimer.value.running && !input.active && !model.voice.state.value.visible }
            assertFalse(model.player.value.playing); assertNull(PlaybackStatus.voiceToken.value)
        } finally { compose.runOnUiThread { controller.release() } }
    }

    @Test fun compoundReceiptSpeaksOnceAndAppliesSpeedBeforeClosingForPlayback() {
        play()
        api.response = VoiceResponse(VoiceAction.Unknown, "Playing the second episode a little faster.", actions = listOf(
            VoiceResponse(VoiceAction.Play, "Playing", api.second), VoiceResponse(VoiceAction.Speed, "Faster", speed = 1.5f)))
        ask("Play the second episode and make it faster")
        compose.waitUntil(10_000) { model.player.value.playing && model.player.value.item?.episodeId == 2 && !model.voice.state.value.visible }
        assertEquals(1.5f, model.player.value.speed); assertEquals(listOf(api.response.spokenResponse), output.said)
    }

    @Test fun filingLaterInACompoundReceiptCannotBeOverwrittenByItsEarlierPlaySnapshot() {
        play()
        api.response = VoiceResponse(VoiceAction.Unknown, "The second episode is marked as played.", actions = listOf(
            VoiceResponse(VoiceAction.Play, "Playing", api.second),
            VoiceResponse(VoiceAction.Played, "Played", api.second.copy(completed = true))))
        ask("Play the second episode then mark it as played"); idle()
        compose.waitUntil(5_000) { model.player.value.playing }
        assertEquals(1, model.player.value.item?.episodeId)
        assertTrue("Compound filing state: ${model.voice.state.value}; requests=${api.requests.size}; confirmed=${api.secondFiled}; spoken=${output.said.size}",
            library.state.value.items.first { it.episodeId == 2 }.completed)
        assertFalse(library.state.value.latestIds.any { id -> library.state.value.items.any { it.id == id && it.episodeId == 2 } })
        assertEquals(1, output.said.size)
    }

    @Test fun conversationPreferencesPersistAndLargeTextScreenRemainsUsable() {
        compose.onNodeWithText("Settings").performClick()
        compose.onNodeWithTag("settings-list").performScrollToNode(hasTestTag("conversation-wait"))
        compose.onNodeWithTag("conversation-wait").performClick()
        compose.onNodeWithText("20 seconds").performClick()
        scenario!!.recreate(); scenario!!.onActivity { activity ->
            model = ViewModelProvider(activity)[MagpieModel::class.java]
            activity.setContent { CompositionLocalProvider(LocalDensity provides Density(LocalDensity.current.density, 2f)) {
                MagpieTheme(darkTheme = true) { MagpieApp(model) }
            } }
        }
        assertEquals(20, model.conversationSettings.value.followUpSeconds)
        api.response = VoiceResponse(VoiceAction.Unknown, "You can ask for a podcast, save an article, or change the listening speed. What would you like to hear?")
        ask("What can I ask?"); idle()
        compose.onNodeWithText("Type a request").assertIsDisplayed(); compose.onNodeWithText("Listen").assertIsDisplayed()
        compose.waitUntil(5_000) { compose.onNodeWithText("Close").isDisplayed() }
        val outputDir = InstrumentationRegistry.getArguments().getString("additionalTestOutputDir") ?: app.filesDir.path
        val screenshot = checkNotNull(InstrumentationRegistry.getInstrumentation().uiAutomation.takeScreenshot())
        File(outputDir, "voice-conversation-large-dark.png").outputStream().use { screenshot.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it) }
        compose.onNodeWithText("Close").assertIsDisplayed()
        scenario!!.recreate(); compose.onNodeWithText("Type a request").assertIsDisplayed()
        compose.onNodeWithText("Close").performClick()
    }
}
