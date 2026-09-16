package com.henrydashwood.magpie

import android.content.Intent
import androidx.appfunctions.*
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import androidx.test.filters.SdkSuppress
import com.henrydashwood.magpie.automation.*
import com.henrydashwood.magpie.data.*
import com.henrydashwood.magpie.playback.PlaybackService
import kotlinx.coroutines.*
import org.junit.*
import org.junit.Assert.*

/** Goes through the platform manager and generated service, including schema serialization. */
@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
@SdkSuppress(minSdkVersion = 36)
class AppFunctionsTest {
    private val app get() = ApplicationProvider.getApplicationContext<MagpieTestApplication>()
    private lateinit var library: AccountLibrary
    private lateinit var api: Api
    private lateinit var manager: AppFunctionManager
    private var scenario: ActivityScenario<MainActivity>? = null
    private var availability: Job? = null
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private lateinit var metadata: List<androidx.appfunctions.metadata.AppFunctionMetadata>
    private lateinit var observer: androidx.media3.session.MediaController
    private val originalRates = mutableMapOf<ContentKind, Float>()
    private fun parameters(id: String = MagpieAppFunctions.FUNCTION_ID_FIND_ITEMS): AppFunctionData.Builder =
        metadata.first { it.id == id }.let { AppFunctionData.Builder(it.parameters, it.components) }
    private val owner get() = checkNotNull(library.state.value.owner)
    private fun itemId(number: Int) = "$owner:episode:$number"
    private val key = ExecuteAppFunctionResponse.Success.PROPERTY_RETURN_VALUE
    private class Api : LibraryApi, LibraryActionApi {
        val short = RemoteEpisode(1, "Short podcast", source = "Test show", audioUrl = "asset:///welcome.wav", durationSeconds = 120, positionSeconds = 12.0)
        val done = short.copy(id = 2, title = "Finished podcast", completed = true, durationSeconds = 60)
        val unknown = short.copy(id = 3, title = "Unknown length", durationSeconds = null)
        var refreshGate: CompletableDeferred<Unit>? = null
        var gate: CompletableDeferred<Unit>? = null
        var episodeGate: CompletableDeferred<Unit>? = null
        var episodeQueries = 0
        var cancelledEpisodes = 0
        var showRows = listOf(short, done, unknown)
        var article: RemoteEpisode? = null
        var completedIds = emptySet<Int>()
        val positions = mutableMapOf<Pair<String, Int>, Double>()
        data class Filing(val token: String, val action: String, val item: Int?, val request: String)
        val filings = mutableListOf<Filing>()
        val cancellations = mutableListOf<Pair<String, String>>()
        val filed = mutableMapOf<Pair<String, Int>, RemoteEpisode>()
        private val receipts = mutableMapOf<Pair<String, String>, com.henrydashwood.magpie.voice.VoiceResponse>()
        private val undo = mutableMapOf<String, RemoteEpisode>()
        var filingGate: CompletableDeferred<Unit>? = null
        var positionGate: CompletableDeferred<Unit>? = null
        var waitingPositions = 0
        var loseFilingReply = false
        private fun row(token: String, episodeId: Int) = (filed[token to episodeId]
            ?: (listOf(short, done, unknown) + listOfNotNull(article)).first { it.id == episodeId }).let {
                it.copy(positionSeconds = positions[token to episodeId] ?: it.positionSeconds, completed = it.completed || episodeId in completedIds)
            }
        override suspend fun libraryAction(token: String, action: String, episodeId: Int?, requestId: String): com.henrydashwood.magpie.voice.VoiceResponse {
            filings += Filing(token, action, episodeId, requestId)
            filingGate?.await()
            receipts[token to requestId]?.let { return it }
            if (token to requestId in cancellations) throw com.henrydashwood.magpie.voice.VoiceFailure(
                "That request was stopped. Any changes already completed remain in your library.")
            val response = if (action == "undo") {
                undo.remove(token)?.let { previous ->
                    filed[token to previous.id] = previous; positions[token to previous.id] = previous.positionSeconds
                    com.henrydashwood.magpie.voice.VoiceResponse(com.henrydashwood.magpie.voice.VoiceAction.Restore, "Restored ${previous.title}.", previous)
                } ?: com.henrydashwood.magpie.voice.VoiceResponse(com.henrydashwood.magpie.voice.VoiceAction.Unknown, "There is no recent action to undo.")
            } else {
                val previous = row(token, checkNotNull(episodeId)); undo[token] = previous
                val changed = when (action) {
                    "mark_played" -> previous.copy(completed = true, positionSeconds = 0.0)
                    "dismiss" -> previous.copy(dismissed = true)
                    "restore" -> previous.copy(completed = false, dismissed = false, positionSeconds = 0.0)
                    else -> error("Unknown filing")
                }
                filed[token to changed.id] = changed; positions[token to changed.id] = changed.positionSeconds
                com.henrydashwood.magpie.voice.VoiceResponse(com.henrydashwood.magpie.voice.VoiceAction.decode(action), "Updated ${changed.title}.", changed)
            }
            receipts[token to requestId] = response
            if (loseFilingReply) { loseFilingReply = false; throw java.io.IOException("Connection lost after committing the change") }
            return response
        }
        override suspend fun cancelLibraryAction(token: String, requestId: String) { cancellations += token to requestId }
        override suspend fun episode(token: String, episodeId: Int): RemoteEpisode {
            episodeQueries++
            try { episodeGate?.await() } catch (failure: CancellationException) { cancelledEpisodes++; throw failure }
            return row(token, episodeId)
        }
        var queries = 0
        var texts = 0
        var cancelledQueries = 0
        override suspend fun userId(token: String) = "functions-$token"
        override suspend fun feeds(token: String): List<LibraryFeed> { refreshGate?.await(); return listOf(LibraryFeed("10", "Test show", 3, false)) }
        override suspend fun latest(token: String) = listOf(short, done, unknown).map { row(token, it.id) }
            .filterNot { token to it.id in filed && (it.completed || it.dismissed) }
        override suspend fun saved(token: String) = listOfNotNull(article).map { row(token, it.id) }
        override suspend fun search(token: String, query: String): List<RemoteEpisode> {
            queries++
            try { gate?.await() } catch (failure: CancellationException) { cancelledQueries++; throw failure }
            return listOf(short, done, unknown)
        }
        override suspend fun episodes(token: String, feedId: String, query: String): List<RemoteEpisode> { search(token, query); return showRows }
        override suspend fun text(token: String, episodeId: Int, contentId: Int?): RemoteText {
            texts++; check(episodeId == 4)
            return RemoteText(4, 40, "A quiet morning leaves room to listen. The trees are full of birds. We follow the path beside the garden and enjoy the day. " .repeat(3), null, 78)
        }
        override suspend fun save(token: String, episodeId: Int?, url: String?): RemoteEpisode = error("Read only")
        override suspend fun remove(token: String, episodeId: Int) { error("Read only") }
        override suspend fun played(token: String, episodeId: Int, played: Boolean) { error("Read only") }
        override suspend fun clearLatest(token: String) { error("Read only") }
        override suspend fun subscribe(token: String, url: String): LibraryFeed = error("Read only")
        override suspend fun position(token: String, episodeId: Int, seconds: Double, completed: Boolean) {
            check(episodeId != 4) { "Rendered article seconds must never reach the podcast progress API" }
            positionGate?.let { waitingPositions++; it.await() }
            positions[token to episodeId] = if (completed) 0.0 else seconds
            filed[token to episodeId]?.let { filed[token to episodeId] = it.copy(completed = completed) }
        }
    }
    @Before fun prepare() = runBlocking {
        // The original API 36 image has only the legacy metadata indexer. The
        // current generated schema is verified on API 36.1 and later images.
        Assume.assumeTrue("Requires the current AppFunctions metadata indexer (API 36.1 test image)",
            android.os.Build.VERSION.SDK_INT_FULL >= android.os.Build.VERSION_CODES_FULL.BAKLAVA_1)
        stopPlayer()
        ContentKind.entries.forEach { originalRates[it] = PreviewStore(app).speed(it) }
        api = Api(); library = AccountLibrary(api, "https://functions-fixture.invalid")
        withContext(Dispatchers.Main) { library.changeSession("one"); app.libraryOverride = library }
        scenario = ActivityScenario.launch(MainActivity::class.java)
        manager = checkNotNull(AppFunctionManager.getInstance(app))
        // Wait for PackageManager/AppSearch indexing after installing the APK.
        withTimeout(60_000) {
            while (true) {
                try {
                    for (id in AppFunctionAvailability.functionIds) manager.setAppFunctionEnabled(id, AppFunctionManager.APP_FUNCTION_STATE_ENABLED)
                    break
                } catch (_: IllegalArgumentException) { delay(500) }
            }
        }
        metadata = manager.searchAppFunctions(AppFunctionSearchSpec(packageNames = setOf(app.packageName)))
        observer = connectObserver()
        availability = scope.launch { AppFunctionAvailability.observe(app, library) }
    }
    @After fun finish() = runBlocking {
        if (!::api.isInitialized) return@runBlocking
        api.refreshGate?.complete(Unit); api.gate?.complete(Unit); api.episodeGate?.complete(Unit)
        api.filingGate?.complete(Unit); api.positionGate?.complete(Unit)
        availability?.cancelAndJoin(); scope.cancel()
        if (::observer.isInitialized && withContext(Dispatchers.Main) { observer.isConnected }) {
            // Await service confirmation before releasing: a queued Pause followed
            // immediately by release can leave foreground playback alive.
            val dismissed = withContext(Dispatchers.Main) { observer.sendCustomCommand(
                androidx.media3.session.SessionCommand(PlaybackService.DISMISS_PLAYER, android.os.Bundle.EMPTY), android.os.Bundle.EMPTY) }
            assertEquals(0, dismissed.get(5, java.util.concurrent.TimeUnit.SECONDS).resultCode)
            waitFor { observer.currentMediaItem == null }
            withContext(Dispatchers.Main) { observer.release() }
        }
        scenario?.close()
        stopPlayer()
        withContext(Dispatchers.Main) { originalRates.forEach { (kind, rate) -> PreviewStore(app).saveSpeed(kind, rate) }; app.libraryOverride = null }
    }
    @Suppress("DEPRECATION") // Inspect only this app's service lifecycle in an isolated emulator test.
    private suspend fun stopPlayer() {
        app.stopService(Intent(app, PlaybackService::class.java))
        withTimeout(15_000) {
            while (app.getSystemService(android.app.ActivityManager::class.java).getRunningServices(Int.MAX_VALUE)
                .any { it.service.className == PlaybackService::class.java.name }) delay(20)
        }
    }
    private suspend fun connectObserver(): androidx.media3.session.MediaController {
        val future = withContext(Dispatchers.Main) {
            androidx.media3.session.MediaController.Builder(app, androidx.media3.session.SessionToken(app,
                android.content.ComponentName(app, PlaybackService::class.java))).buildAsync()
        }
        return future.get(15, java.util.concurrent.TimeUnit.SECONDS)
    }
    private suspend fun waitFor(condition: () -> Boolean) = withTimeout(10_000) {
        while (!withContext(Dispatchers.Main) { condition() }) delay(20)
    }
    private suspend fun play(number: Int = 1): AppFunctionData = success(MagpieAppFunctions.FUNCTION_ID_PLAY_LISTENING_ITEM,
        parameters(MagpieAppFunctions.FUNCTION_ID_PLAY_LISTENING_ITEM).setString("itemId", itemId(number)).build())
        .getAppFunctionData(key)!!
    private suspend fun value(id: String, name: String, number: Double) = success(id,
        parameters(id).setDouble(name, number).build()).getAppFunctionData(key)!!
    private suspend fun execute(id: String, data: AppFunctionData = AppFunctionData.EMPTY) = withTimeout(150_000) {
        manager.executeAppFunction(ExecuteAppFunctionRequest(app.packageName, id, data))
    }
    private suspend fun success(id: String, data: AppFunctionData = AppFunctionData.EMPTY): AppFunctionData {
        val result = execute(id, data)
        assertTrue(result.toString(), result is ExecuteAppFunctionResponse.Success)
        return (result as ExecuteAppFunctionResponse.Success).returnValue
    }
    @Test fun listAndFindUseScopedIdsAndPreserveTheDisplayedSearch() = runBlocking {
        withContext(Dispatchers.Main) { library.search(null, "existing") }
        val displayed = library.state.value.searchResults
        val shows = success(MagpieAppFunctions.FUNCTION_ID_LIST_SHOWS).getAppFunctionDataList(key)!!
        assertEquals(1, shows.size)
        val showId = shows.single().getString("id")!!
        assertTrue(showId.startsWith(library.state.value.owner!!))
        val found = success(MagpieAppFunctions.FUNCTION_ID_FIND_ITEMS, parameters()
            .setString("showId", showId).setBoolean("unheardOnly", true).setDouble("maximumMinutes", 3.0).build())
            .getAppFunctionDataList(key)!!
        assertEquals(listOf("Short podcast"), found.map { it.getString("title") })
        assertEquals(120, found.single().getInt("durationSeconds"))
        assertEquals(displayed, library.state.value.searchResults)
        assertEquals(0, api.texts)
    }
    @Test fun defaultSearchIncludesUnknownDurationAndLimitsResults() = runBlocking {
        val found = success(MagpieAppFunctions.FUNCTION_ID_FIND_ITEMS).getAppFunctionDataList(key)!!
        assertEquals(3, found.size); assertNull(found.last().getIntOrNull("durationSeconds"))
        val limited = success(MagpieAppFunctions.FUNCTION_ID_FIND_ITEMS,
            parameters().setInt("maxResults", 1).build()).getAppFunctionDataList(key)!!
        assertEquals(1, limited.size)
    }
    @Test fun invalidArgumentsDoNotQueryTheLibrary() = runBlocking {
        for (data in listOf(parameters().setInt("maxResults", 0).build(),
            parameters().setDouble("maximumMinutes", -1.0).build(),
            parameters().setString("query", "x".repeat(201)).build())) {
            val result = execute(MagpieAppFunctions.FUNCTION_ID_FIND_ITEMS, data)
            assertTrue(result.toString(), result is ExecuteAppFunctionResponse.Error && result.error is AppFunctionInvalidArgumentException)
        }
        assertEquals(0, api.queries)
    }
    @Test fun anOldAccountsShowCannotBeUsedAfterSwitchingAccounts() = runBlocking {
        val old = success(MagpieAppFunctions.FUNCTION_ID_LIST_SHOWS).getAppFunctionDataList(key)!!.single().getString("id")!!
        withContext(Dispatchers.Main) { library.changeSession("two") }
        val result = execute(MagpieAppFunctions.FUNCTION_ID_FIND_ITEMS, parameters().setString("showId", old).build())
        assertTrue(result.toString(), result is ExecuteAppFunctionResponse.Error && result.error is AppFunctionElementNotFoundException)
        assertEquals(0, api.queries)
    }
    @Test fun signedOutInvocationsCannotReadTheSampleLibraryEvenIfStillEnabled() = runBlocking {
        availability?.cancelAndJoin()
        withContext(Dispatchers.Main) { library.changeSession(null) }
        val result = execute(MagpieAppFunctions.FUNCTION_ID_LIST_SHOWS)
        assertTrue(result.toString(), result is ExecuteAppFunctionResponse.Error && result.error is AppFunctionPermissionRequiredException)
    }
    @Test fun accountChangeDiscardsAnInFlightLookup() = runBlocking {
        availability?.cancelAndJoin()
        api.gate = CompletableDeferred()
        val pending = async { execute(MagpieAppFunctions.FUNCTION_ID_FIND_ITEMS, parameters().setString("query", "podcast").build()) }
        withTimeout(5_000) { while (withContext(Dispatchers.Main) { api.queries } == 0) delay(20) }
        withContext(Dispatchers.Main) { library.changeSession(null); api.gate!!.complete(Unit) }
        val result = pending.await()
        assertTrue(result.toString(), result is ExecuteAppFunctionResponse.Error && result.error is AppFunctionCancelledException)
        assertFalse(library.state.value.live)
        assertTrue(library.state.value.items.none { it.title == "Short podcast" })
    }
    @Test fun callerCancellationStopsTheLookupAndTheNextCallStillWorks() = runBlocking {
        api.gate = CompletableDeferred()
        val pending = async { execute(MagpieAppFunctions.FUNCTION_ID_FIND_ITEMS, parameters().setString("query", "podcast").build()) }
        withTimeout(5_000) { while (withContext(Dispatchers.Main) { api.queries } == 0) delay(20) }
        pending.cancelAndJoin()
        withTimeout(5_000) { while (withContext(Dispatchers.Main) { api.cancelledQueries } == 0) delay(20) }
        withContext(Dispatchers.Main) { api.gate = null }
        assertEquals(3, success(MagpieAppFunctions.FUNCTION_ID_FIND_ITEMS).getAppFunctionDataList(key)!!.size)
    }
    @Test fun discoveryDisablesAfterSignOutAndEnablesAfterSignIn() = runBlocking {
        val names = AppFunctionAvailability.functionIds.map { androidx.appfunctions.metadata.AppFunctionName(app.packageName, it) }
        withContext(Dispatchers.Main) { library.changeSession(null) }
        withTimeout(5_000) { while (manager.getAppFunctionStates(names).any { it.isEnabled }) delay(20) }
        val result = execute(MagpieAppFunctions.FUNCTION_ID_LIST_SHOWS)
        assertTrue(result.toString(), result is ExecuteAppFunctionResponse.Error && result.error is AppFunctionDisabledException)
        withContext(Dispatchers.Main) { library.changeSession("two") }
        withTimeout(5_000) { while (manager.getAppFunctionStates(names).any { !it.isEnabled }) delay(20) }
        assertEquals(1, success(MagpieAppFunctions.FUNCTION_ID_LIST_SHOWS).getAppFunctionDataList(key)!!.size)
    }
    @Test fun listeningStatusDoesNotStartPlayback() = runBlocking {
        val result = success(MagpieAppFunctions.FUNCTION_ID_GET_LISTENING_STATUS).getAppFunctionData(key)!!
        assertFalse(result.getBoolean("playing")); assertNull(result.getAppFunctionData("item"))
        assertEquals(0.0, result.getDouble("positionSeconds"), 0.01)
    }
    @Test fun playbackControlsConfirmTheServiceStateAndPreservePositions() = runBlocking {
        val started = play().getAppFunctionData("status")!!
        assertTrue(started.getBoolean("playing"))
        waitFor { observer.isPlaying && observer.currentMediaItem?.mediaId == itemId(1) }
        val paused = success(MagpieAppFunctions.FUNCTION_ID_PAUSE_LISTENING).getAppFunctionData(key)!!
        assertFalse(paused.getBoolean("playing")); waitFor { !observer.isPlaying }
        val sought = value(MagpieAppFunctions.FUNCTION_ID_SEEK_LISTENING, "positionSeconds", 20.0)
        assertEquals(20.0, sought.getDouble("positionSeconds"), 0.1)
        val skipped = value(MagpieAppFunctions.FUNCTION_ID_SKIP_LISTENING, "seconds", -5.0)
        assertEquals(15.0, skipped.getDouble("positionSeconds"), 0.1)
        val before = skipped.getDouble("speed")
        assertEquals(1.5, value(MagpieAppFunctions.FUNCTION_ID_SET_LISTENING_SPEED, "speed", 1.5).getDouble("speed"), 0.01)
        assertEquals(before, success(MagpieAppFunctions.FUNCTION_ID_UNDO_LISTENING_SPEED).getAppFunctionData(key)!!.getDouble("speed"), 0.01)
        val clock = System.currentTimeMillis()
        val sleep = value(MagpieAppFunctions.FUNCTION_ID_SET_LISTENING_SLEEP_TIMER, "minutes", 2.1)
        assertTrue(sleep.getLong("sleepEndsAtMillis") - clock in 179_000..185_000)
        val cancelled = success(MagpieAppFunctions.FUNCTION_ID_CANCEL_LISTENING_SLEEP_TIMER).getAppFunctionData(key)!!
        assertNull(cancelled.getLongOrNull("sleepEndsAtMillis")); assertFalse(cancelled.getBoolean("playing"))
        val continued = success(MagpieAppFunctions.FUNCTION_ID_CONTINUE_LISTENING).getAppFunctionData(key)!!.getAppFunctionData("status")!!
        assertTrue(continued.getBoolean("playing")); assertTrue(continued.getDouble("positionSeconds") >= 15)
        waitFor { observer.isPlaying && observer.currentPosition >= 15_000 }
    }
    @Test fun latestShowSkipsCompletedItemsAndCompletedExplicitPlaybackRestarts() = runBlocking {
        api.showRows = listOf(api.done, api.unknown, api.short)
        val latest = success(MagpieAppFunctions.FUNCTION_ID_PLAY_LATEST_LISTENING_ITEM,
            parameters(MagpieAppFunctions.FUNCTION_ID_PLAY_LATEST_LISTENING_ITEM).setString("showId", "$owner:feed:10").build())
            .getAppFunctionData(key)!!.getAppFunctionData("status")!!
        assertEquals(itemId(3), latest.getAppFunctionData("item")!!.getString("id"))
        val restarted = play(2).getAppFunctionData("status")!!
        assertEquals(itemId(2), restarted.getAppFunctionData("item")!!.getString("id"))
        assertTrue(restarted.getDouble("positionSeconds") < 2)
    }
    @Test fun invalidControlsLeavePlaybackUnchangedAndSpeedUndoDetectsNewerChanges() = runBlocking {
        play()
        val version = com.henrydashwood.magpie.playback.PlaybackStatus.controlVersion.value
        for ((function, field, invalid) in listOf(
            Triple(MagpieAppFunctions.FUNCTION_ID_SET_LISTENING_SPEED, "speed", 3.1),
            Triple(MagpieAppFunctions.FUNCTION_ID_SET_LISTENING_SLEEP_TIMER, "minutes", 0.0),
            Triple(MagpieAppFunctions.FUNCTION_ID_SEEK_LISTENING, "positionSeconds", -1.0),
            Triple(MagpieAppFunctions.FUNCTION_ID_SKIP_LISTENING, "seconds", 86_401.0))) {
            val result = execute(function, parameters(function).setDouble(field, invalid).build())
            assertTrue(result.toString(), result is ExecuteAppFunctionResponse.Error && result.error is AppFunctionInvalidArgumentException)
        }
        assertEquals(version, com.henrydashwood.magpie.playback.PlaybackStatus.controlVersion.value)
        value(MagpieAppFunctions.FUNCTION_ID_SET_LISTENING_SPEED, "speed", 1.25)
        withContext(Dispatchers.Main) { observer.setPlaybackSpeed(1.75f) }
        waitFor { PreviewStore(app).speed(ContentKind.Podcast) == 1.75f }
        assertTrue(execute(MagpieAppFunctions.FUNCTION_ID_UNDO_LISTENING_SPEED) is ExecuteAppFunctionResponse.Error)
        assertEquals(1.75f, withContext(Dispatchers.Main) { observer.playbackParameters.speed })
    }
    @Test fun anExternalPauseCancelsPendingPlayWithoutResumingTheOldItem() = runBlocking {
        play(); api.episodeGate = CompletableDeferred()
        val count = api.episodeQueries
        val pending = async { execute(MagpieAppFunctions.FUNCTION_ID_PLAY_LISTENING_ITEM,
            parameters(MagpieAppFunctions.FUNCTION_ID_PLAY_LISTENING_ITEM).setString("itemId", itemId(2)).build()) }
        waitFor { api.episodeQueries > count }
        withContext(Dispatchers.Main) { observer.pause() }
        val result = pending.await()
        assertTrue(result.toString(), result is ExecuteAppFunctionResponse.Error && result.error is AppFunctionCancelledException)
        api.episodeGate!!.complete(Unit)
        waitFor { api.cancelledEpisodes > 0 && !observer.isPlaying }
        assertEquals(itemId(1), withContext(Dispatchers.Main) { observer.currentMediaItem?.mediaId })
    }
    @Test fun accountChangeCancelsPendingPlay() = runBlocking {
        availability?.cancelAndJoin(); api.episodeGate = CompletableDeferred()
        val id = itemId(1)
        val pending = async { execute(MagpieAppFunctions.FUNCTION_ID_PLAY_LISTENING_ITEM,
            parameters(MagpieAppFunctions.FUNCTION_ID_PLAY_LISTENING_ITEM).setString("itemId", id).build()) }
        waitFor { api.episodeQueries > 0 }
        withContext(Dispatchers.Main) { library.changeSession(null) }
        api.episodeGate!!.complete(Unit)
        val result = pending.await()
        assertTrue(result.toString(), result is ExecuteAppFunctionResponse.Error && result.error is AppFunctionCancelledException)
        waitFor { observer.currentMediaItem == null && !observer.isPlaying }
    }
    @Test fun callerCancellationCancelsPreparationAndAllowsAFreshRequest() = runBlocking {
        api.episodeGate = CompletableDeferred()
        val pending = async { play() }
        waitFor { api.episodeQueries > 0 }
        pending.cancelAndJoin()
        waitFor { api.cancelledEpisodes > 0 }
        api.episodeGate = null
        assertFalse(withContext(Dispatchers.Main) { observer.isPlaying })
        assertTrue(play().getAppFunctionData("status")!!.getBoolean("playing"))
    }
    @Test fun aFailedPlaybackLookupDoesNotResumeThePreviousItem() = runBlocking {
        play()
        val result = execute(MagpieAppFunctions.FUNCTION_ID_PLAY_LISTENING_ITEM,
            parameters(MagpieAppFunctions.FUNCTION_ID_PLAY_LISTENING_ITEM).setString("itemId", itemId(999)).build())
        assertTrue(result.toString(), result is ExecuteAppFunctionResponse.Error)
        waitFor { !observer.isPlaying }
        assertEquals(itemId(1), withContext(Dispatchers.Main) { observer.currentMediaItem?.mediaId })
    }
    @Test fun continueStartsAColdServiceWithNoActivityVisible() = runBlocking {
        play(); success(MagpieAppFunctions.FUNCTION_ID_PAUSE_LISTENING)
        value(MagpieAppFunctions.FUNCTION_ID_SEEK_LISTENING, "positionSeconds", 22.0)
        waitFor { (api.positions["one" to 1] ?: 0.0) >= 22 }
        val dismissed = withContext(Dispatchers.Main) { observer.sendCustomCommand(
            androidx.media3.session.SessionCommand(PlaybackService.DISMISS_PLAYER, android.os.Bundle.EMPTY), android.os.Bundle.EMPTY) }
        assertEquals(0, dismissed.get(5, java.util.concurrent.TimeUnit.SECONDS).resultCode)
        waitFor { observer.currentMediaItem == null }
        withContext(Dispatchers.Main) { observer.release() }
        scenario!!.close(); scenario = null; stopPlayer()
        val continued = success(MagpieAppFunctions.FUNCTION_ID_CONTINUE_LISTENING).getAppFunctionData(key)!!
        val status = continued.getAppFunctionData("status")!!
        assertTrue("Cold service did not start: $continued", status.getBoolean("playing"))
        assertTrue("Cold position was ${status.getDouble("positionSeconds")}", status.getDouble("positionSeconds") >= 22)
        observer = connectObserver()
        waitFor { observer.isPlaying && observer.currentMediaItem?.mediaId == itemId(1) }
    }
    @Test fun articlePlaybackAndSeekingUseTheSameOfflineRendererWithoutPodcastProgressWrites() = runBlocking {
        api.article = RemoteEpisode(4, "Assistant reading", source = "Writing", contentId = 40)
        withContext(Dispatchers.Main) { library.refresh() }
        val result = play(4).getAppFunctionData("status")!!
        assertTrue(result.getBoolean("playing")); assertEquals("article", result.getAppFunctionData("item")!!.getString("kind"))
        assertEquals(1, api.texts)
        success(MagpieAppFunctions.FUNCTION_ID_PAUSE_LISTENING)
        value(MagpieAppFunctions.FUNCTION_ID_SEEK_LISTENING, "positionSeconds", 4.0)
        val podcastSpeed = PreviewStore(app).speed(ContentKind.Podcast)
        value(MagpieAppFunctions.FUNCTION_ID_SET_LISTENING_SPEED, "speed", 1.25)
        assertEquals(podcastSpeed, PreviewStore(app).speed(ContentKind.Podcast))
        assertNotNull(PreviewStore(app).bookmark(itemId(4)))
        assertTrue(api.positions.keys.none { it.second == 4 })
        val continued = success(MagpieAppFunctions.FUNCTION_ID_CONTINUE_LISTENING).getAppFunctionData(key)!!.getAppFunctionData("status")!!
        assertTrue(continued.getDouble("positionSeconds") >= 4); assertEquals(1, api.texts)
    }
    @Test fun theServiceRejectsStaleAccountCommandsWithoutChangingPlayback() = runBlocking {
        play()
        val controls = com.henrydashwood.magpie.playback.PlaybackStatus.controlVersion.value
        val future = withContext(Dispatchers.Main) { observer.sendCustomCommand(
            androidx.media3.session.SessionCommand(PlaybackService.AUTOMATION_CONTROL, android.os.Bundle.EMPTY),
            android.os.Bundle().apply { putString("owner", "stale-owner"); putInt("revision", library.state.value.revision); putString("action", "pause") }) }
        assertEquals(androidx.media3.session.SessionError.ERROR_PERMISSION_DENIED, future.get(5, java.util.concurrent.TimeUnit.SECONDS).resultCode)
        assertEquals(controls, com.henrydashwood.magpie.playback.PlaybackStatus.controlVersion.value)
        assertTrue(withContext(Dispatchers.Main) { observer.isPlaying })
    }
    @Test fun staleItemAndShowIdsCannotInterruptTheCurrentAccountsPlayback() = runBlocking {
        play()
        val controls = com.henrydashwood.magpie.playback.PlaybackStatus.controlVersion.value
        for ((function, field, id) in listOf(
            Triple(MagpieAppFunctions.FUNCTION_ID_PLAY_LISTENING_ITEM, "itemId", "old-account:episode:1"),
            Triple(MagpieAppFunctions.FUNCTION_ID_PLAY_LATEST_LISTENING_ITEM, "showId", "old-account:feed:10"))) {
            assertTrue(execute(function, parameters(function).setString(field, id).build()) is ExecuteAppFunctionResponse.Error)
            assertEquals(controls, com.henrydashwood.magpie.playback.PlaybackStatus.controlVersion.value)
            assertTrue(withContext(Dispatchers.Main) { observer.isPlaying })
        }
    }
    @Test fun pauseDoesNotWaitForAnUnrelatedLibraryRefresh() = runBlocking {
        play(); api.refreshGate = CompletableDeferred()
        val refresh = launch(Dispatchers.Main) { library.refresh() }
        waitFor { library.state.value.loading }
        try {
            val status = withTimeout(3_000) { success(MagpieAppFunctions.FUNCTION_ID_PAUSE_LISTENING).getAppFunctionData(key)!! }
            assertFalse(status.getBoolean("playing"))
            assertTrue(library.state.value.loading)
        } finally { api.refreshGate!!.complete(Unit); refresh.join() }
    }
    @Test fun explicitlyPlayingAnAlreadyLoadedCompletedItemRestartsIt() = runBlocking {
        play(); success(MagpieAppFunctions.FUNCTION_ID_PAUSE_LISTENING)
        value(MagpieAppFunctions.FUNCTION_ID_SEEK_LISTENING, "positionSeconds", 20.0)
        api.completedIds = setOf(1)
        val restarted = play().getAppFunctionData("status")!!
        assertTrue(restarted.getBoolean("playing"))
        assertTrue(restarted.getDouble("positionSeconds") < 2)
    }

    private fun filing(filing: String, id: String? = null, startNewChange: Boolean? = null) = parameters(MagpieAppFunctions.FUNCTION_ID_FILE_LISTENING_ITEM)
        .setString("filing", filing).apply {
            id?.let { setString("itemId", it) }; startNewChange?.let { setBoolean("startNewChange", it) }
        }.build()

    @Test fun filingTheCurrentPodcastAndUndoPreserveItsConfirmedBookmark() = runBlocking {
        play(); success(MagpieAppFunctions.FUNCTION_ID_PAUSE_LISTENING)
        value(MagpieAppFunctions.FUNCTION_ID_SEEK_LISTENING, "positionSeconds", 22.0)
        val changed = success(MagpieAppFunctions.FUNCTION_ID_FILE_LISTENING_ITEM, filing("played")).getAppFunctionData(key)!!
        assertTrue(changed.getBoolean("changed")); assertTrue(changed.getAppFunctionData("item")!!.getBoolean("completed"))
        waitFor { observer.currentMediaItem == null }
        assertFalse(itemId(1) in library.state.value.latestIds)
        val undo = success(MagpieAppFunctions.FUNCTION_ID_UNDO_LAST_LIBRARY_ACTION).getAppFunctionData(key)!!
        assertTrue(undo.getBoolean("changed")); assertFalse(undo.getAppFunctionData("item")!!.getBoolean("completed"))
        assertEquals(22.0, api.positions["one" to 1]!!, 0.2)
        val resumed = play().getAppFunctionData("status")!!
        assertTrue(resumed.getDouble("positionSeconds") in 21.8..24.0)
    }
    @Test fun filingAnotherItemPreservesPlaybackAndCanRestoreLatest() = runBlocking {
        play()
        success(MagpieAppFunctions.FUNCTION_ID_FILE_LISTENING_ITEM, filing("dismissed", itemId(3)))
        waitFor { observer.isPlaying && observer.currentMediaItem?.mediaId == itemId(1) }
        assertFalse(itemId(3) in library.state.value.latestIds)
        success(MagpieAppFunctions.FUNCTION_ID_FILE_LISTENING_ITEM, filing("restored", itemId(3)))
        assertTrue(itemId(3) in library.state.value.latestIds)
        waitFor { observer.isPlaying && observer.currentMediaItem?.mediaId == itemId(1) }
    }
    @Test fun staleFilingTargetsAndInvalidChoicesNeverInterruptPlayback() = runBlocking {
        play()
        val controls = com.henrydashwood.magpie.playback.PlaybackStatus.controlVersion.value
        for (data in listOf(filing("played", "old-account:episode:1"), filing("invalid", itemId(1)), filing("played", "$owner:episode:-1")))
            assertTrue(execute(MagpieAppFunctions.FUNCTION_ID_FILE_LISTENING_ITEM, data) is ExecuteAppFunctionResponse.Error)
        assertTrue(api.filings.isEmpty())
        withContext(Dispatchers.Main) { assertTrue(observer.isPlaying); assertEquals(itemId(1), observer.currentMediaItem?.mediaId) }
        assertEquals(controls, com.henrydashwood.magpie.playback.PlaybackStatus.controlVersion.value)
    }
    @Test fun aLostFilingReplyIsRecoveredWithoutReplacingTheUndoSnapshot() = runBlocking {
        play(); success(MagpieAppFunctions.FUNCTION_ID_PAUSE_LISTENING)
        value(MagpieAppFunctions.FUNCTION_ID_SEEK_LISTENING, "positionSeconds", 22.0)
        api.loseFilingReply = true
        assertTrue(execute(MagpieAppFunctions.FUNCTION_ID_FILE_LISTENING_ITEM, filing("played", itemId(1))) is ExecuteAppFunctionResponse.Error)
        withContext(Dispatchers.Main) { assertFalse(observer.isPlaying) }
        success(MagpieAppFunctions.FUNCTION_ID_FILE_LISTENING_ITEM, filing("played", itemId(1)))
        assertEquals(api.filings[0].request, api.filings[1].request)
        success(MagpieAppFunctions.FUNCTION_ID_UNDO_LAST_LIBRARY_ACTION)
        assertEquals(22.0, api.positions["one" to 1]!!, 0.2)
    }
    @Test fun overlappingFilingCannotStealTheActivePlaybackHold() = runBlocking {
        play(); api.filingGate = CompletableDeferred()
        val first = async { execute(MagpieAppFunctions.FUNCTION_ID_FILE_LISTENING_ITEM, filing("played", itemId(1))) }
        waitFor { api.filings.size == 1 }
        val hold = com.henrydashwood.magpie.playback.PlaybackStatus.voiceToken.value
        assertTrue(execute(MagpieAppFunctions.FUNCTION_ID_FILE_LISTENING_ITEM, filing("dismissed", itemId(3))) is ExecuteAppFunctionResponse.Error)
        assertEquals(hold, com.henrydashwood.magpie.playback.PlaybackStatus.voiceToken.value)
        api.filingGate!!.complete(Unit)
        assertTrue(first.await() is ExecuteAppFunctionResponse.Success)
        assertEquals(1, api.filings.size)
    }
    @Test fun retryingACurrentItemFilingKeepsItsOriginalTargetAfterPlaybackChanges() = runBlocking {
        play(); api.loseFilingReply = true
        assertTrue(execute(MagpieAppFunctions.FUNCTION_ID_FILE_LISTENING_ITEM, filing("played")) is ExecuteAppFunctionResponse.Error)
        play(3)
        success(MagpieAppFunctions.FUNCTION_ID_FILE_LISTENING_ITEM, filing("played"))
        assertEquals(listOf(1, 1), api.filings.map { it.item })
        assertEquals(api.filings[0].request, api.filings[1].request)
        waitFor { observer.isPlaying && observer.currentMediaItem?.mediaId == itemId(3) }
        assertFalse(api.filed.containsKey("one" to 3))
        assertTrue(api.filed["one" to 1]!!.completed)
    }
    @Test fun anUncertainFilingCannotBeOverwrittenWhenPlaybackMovesToAnotherItem() = runBlocking {
        play(); api.loseFilingReply = true
        assertTrue(execute(MagpieAppFunctions.FUNCTION_ID_FILE_LISTENING_ITEM, filing("played")) is ExecuteAppFunctionResponse.Error)
        play(3); success(MagpieAppFunctions.FUNCTION_ID_PAUSE_LISTENING)
        // The service serializes reports: observing the new item's report also
        // proves any older queued report has completed.
        waitFor { "one" to 3 in api.positions }
        assertTrue(api.filed["one" to 1]!!.completed)
        assertEquals(0.0, api.positions["one" to 1]!!, 0.0)
        success(MagpieAppFunctions.FUNCTION_ID_FILE_LISTENING_ITEM, filing("played"))
        success(MagpieAppFunctions.FUNCTION_ID_UNDO_LAST_LIBRARY_ACTION)
        play(); success(MagpieAppFunctions.FUNCTION_ID_PAUSE_LISTENING)
        value(MagpieAppFunctions.FUNCTION_ID_SEEK_LISTENING, "positionSeconds", 24.0)
        waitFor { api.positions["one" to 1]?.let { it >= 24.0 } == true }
    }
    @Test fun externalPauseCancelsFilingAndDoesNotResumeAudio() = runBlocking {
        play(); api.filingGate = CompletableDeferred()
        val first = async { runCatching { execute(MagpieAppFunctions.FUNCTION_ID_FILE_LISTENING_ITEM, filing("played", itemId(1))) } }
        waitFor { api.filings.size == 1 }
        withContext(Dispatchers.Main) { observer.pause() }
        withTimeout(10_000) { first.await() }
        waitFor { api.cancellations.size == 1 }
        assertEquals("one" to api.filings.single().request, api.cancellations.single())
        withContext(Dispatchers.Main) { assertFalse(observer.isPlaying) }
        assertTrue(api.filed.isEmpty())
    }
    @Test fun accountChangeCancelsFilingUsingOnlyItsOriginalAccount() = runBlocking {
        play(); api.filingGate = CompletableDeferred()
        val previousOwner = owner
        val first = async { runCatching { execute(MagpieAppFunctions.FUNCTION_ID_FILE_LISTENING_ITEM, filing("played", itemId(1))) } }
        waitFor { api.filings.size == 1 }
        withContext(Dispatchers.Main) { library.changeSession("two") }
        withTimeout(10_000) { first.await() }
        waitFor { api.cancellations.size == 1 }
        assertEquals("one" to api.filings.single().request, api.cancellations.single())
        assertTrue(library.state.value.items.none { it.id.startsWith("$previousOwner:") })
        assertTrue(api.filed.isEmpty())
    }
    @Test fun callerCancellationCancelsItsFilingRequestAndLeavesPlaybackPaused() = runBlocking {
        play(); api.filingGate = CompletableDeferred()
        val first = launch { execute(MagpieAppFunctions.FUNCTION_ID_FILE_LISTENING_ITEM, filing("played", itemId(1))) }
        waitFor { api.filings.size == 1 }
        first.cancelAndJoin()
        waitFor { api.cancellations.size == 1 }
        assertEquals("one" to api.filings.single().request, api.cancellations.single())
        withContext(Dispatchers.Main) { assertFalse(observer.isPlaying) }
        assertTrue(api.filed.isEmpty())
    }
    @Test fun aStoppedRequestIsNotRepeatedUntilANewChangeIsExplicitlyRequested() = runBlocking {
        play(); api.filingGate = CompletableDeferred()
        val first = launch { execute(MagpieAppFunctions.FUNCTION_ID_FILE_LISTENING_ITEM, filing("played", itemId(1))) }
        waitFor { api.filings.size == 1 }; first.cancelAndJoin()
        waitFor { api.cancellations.size == 1 }; api.filingGate!!.complete(Unit)
        val original = api.filings.single().request
        assertTrue(execute(MagpieAppFunctions.FUNCTION_ID_FILE_LISTENING_ITEM, filing("played", itemId(1))) is ExecuteAppFunctionResponse.Error)
        assertEquals(original, api.filings.last().request); assertTrue(api.filed.isEmpty())
        success(MagpieAppFunctions.FUNCTION_ID_FILE_LISTENING_ITEM, filing("played", itemId(1), startNewChange = true))
        assertNotEquals(original, api.filings.last().request)
        assertTrue(api.filed["one" to 1]!!.completed)
    }
    @Test fun filingDrainsOlderProgressBeforeCommittingTheServerChange() = runBlocking {
        play(); success(MagpieAppFunctions.FUNCTION_ID_PAUSE_LISTENING)
        api.positionGate = CompletableDeferred()
        value(MagpieAppFunctions.FUNCTION_ID_SEEK_LISTENING, "positionSeconds", 20.0)
        waitFor { api.waitingPositions > 0 }
        val first = async { execute(MagpieAppFunctions.FUNCTION_ID_FILE_LISTENING_ITEM, filing("played", itemId(1))) }
        waitFor { com.henrydashwood.magpie.playback.PlaybackStatus.voiceToken.value != null }
        assertTrue(api.filings.isEmpty())
        api.positionGate!!.complete(Unit)
        assertTrue(first.await() is ExecuteAppFunctionResponse.Success)
        assertTrue(api.filed["one" to 1]!!.completed)
        success(MagpieAppFunctions.FUNCTION_ID_UNDO_LAST_LIBRARY_ACTION)
        assertEquals(20.0, api.positions["one" to 1]!!, 0.2)
    }
    @Test fun articleFilingAndUndoKeepTheTextBookmarkWithoutPodcastProgressWrites() = runBlocking {
        api.article = RemoteEpisode(4, "Test article", contentId = 40, wordCount = 78)
        withContext(Dispatchers.Main) { library.refresh() }
        play(4); success(MagpieAppFunctions.FUNCTION_ID_PAUSE_LISTENING)
        value(MagpieAppFunctions.FUNCTION_ID_SEEK_LISTENING, "positionSeconds", 4.0)
        val store = PreviewStore(app)
        val before = store.bookmark(itemId(4))
        assertNotNull(before)
        success(MagpieAppFunctions.FUNCTION_ID_FILE_LISTENING_ITEM, filing("played", itemId(4)))
        assertNull(store.bookmark(itemId(4)))
        success(MagpieAppFunctions.FUNCTION_ID_UNDO_LAST_LIBRARY_ACTION)
        assertEquals(before, store.bookmark(itemId(4)))
        assertFalse(api.positions.keys.any { it.second == 4 && api.positions[it] != 0.0 })
    }
    @Test fun unavailableUndoReportsNoChangeAndFilingNeedsATargetWhenNothingIsLoaded() = runBlocking {
        assertTrue(execute(MagpieAppFunctions.FUNCTION_ID_FILE_LISTENING_ITEM, filing("played")) is ExecuteAppFunctionResponse.Error)
        assertTrue(api.filings.isEmpty())
        val undo = success(MagpieAppFunctions.FUNCTION_ID_UNDO_LAST_LIBRARY_ACTION).getAppFunctionData(key)!!
        assertFalse(undo.getBoolean("changed")); assertEquals("There is no recent action to undo.", undo.getString("message"))
        withContext(Dispatchers.Main) { assertFalse(observer.isPlaying); assertNull(observer.currentMediaItem) }
    }
}
