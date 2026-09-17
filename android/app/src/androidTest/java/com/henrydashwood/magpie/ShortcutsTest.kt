package com.henrydashwood.magpie

import android.Manifest
import android.app.PendingIntent
import androidx.appfunctions.*
import androidx.test.filters.SdkSuppress
import com.henrydashwood.magpie.automation.MagpieAppFunctions
import android.content.ComponentName
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ShortcutManager
import androidx.activity.compose.setContent
import androidx.activity.compose.LocalActivityResultRegistryOwner
import androidx.activity.result.ActivityResultRegistry
import androidx.activity.result.ActivityResultRegistryOwner
import androidx.activity.result.contract.ActivityResultContract
import androidx.core.app.ActivityOptionsCompat
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.Density
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.lifecycle.ViewModelProvider
import androidx.media3.session.MediaController
import androidx.media3.session.SessionToken
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import androidx.test.platform.app.InstrumentationRegistry
import com.henrydashwood.magpie.data.*
import com.henrydashwood.magpie.playback.PlaybackService
import com.henrydashwood.magpie.shortcuts.*
import com.henrydashwood.magpie.ui.MagpieApp
import com.henrydashwood.magpie.ui.MagpieTheme
import com.henrydashwood.magpie.ui.AskConversation
import com.henrydashwood.magpie.voice.*
import kotlinx.coroutines.*
import org.junit.*
import org.junit.Assert.*
import java.io.File
import java.util.concurrent.TimeUnit

class ShortcutsTest {
    @get:Rule val compose = createEmptyComposeRule()
    private val app get() = ApplicationProvider.getApplicationContext<MagpieTestApplication>()
    private lateinit var api: Api
    private lateinit var library: AccountLibrary
    private lateinit var model: MagpieModel
    private lateinit var launchIntent: Intent
    private var scenario: ActivityScenario<MainActivity>? = null
    private var externalActivity: MainActivity? = null
    private var listens = 0
    private var microphoneActive = false
    private val owner get() = checkNotNull(library.state.value.owner)
    private class Api : LibraryApi {
        val first = RemoteEpisode(1, "Shortcut first podcast", source = "Shortcut show", feedUrl = "https://fixture.invalid/feed", audioUrl = "asset:///welcome.wav", positionSeconds = 12.0)
        val second = first.copy(id = 2, title = "Shortcut second podcast", positionSeconds = 0.0)
        val hidden = first.copy(id = 7, title = "An older episode", positionSeconds = 18.0)
        var latestCalls = 0
        var episodeCalls = 0
        var episodeGate: CompletableDeferred<Unit>? = null
        var textGate: CompletableDeferred<Unit>? = null
        var texts = 0
        var cancelledTexts = 0
        var latestRows = listOf(first, second)
        var following = true
        override suspend fun userId(token: String) = "shortcut-user-$token"
        override suspend fun feeds(token: String) = if (following) listOf(LibraryFeed("10", "Shortcut show", 2, false, "https://fixture.invalid/feed")) else emptyList()
        override suspend fun latest(token: String): List<RemoteEpisode> { latestCalls++; return latestRows }
        override suspend fun saved(token: String) = emptyList<RemoteEpisode>()
        override suspend fun episodes(token: String, feedId: String, query: String) = listOf(second)
        override suspend fun search(token: String, query: String) = emptyList<RemoteEpisode>()
        override suspend fun episode(token: String, episodeId: Int): RemoteEpisode {
            episodeCalls++; episodeGate?.await()
            return listOf(first, second, hidden).first { it.id == episodeId }
        }
        override suspend fun text(token: String, episodeId: Int, contentId: Int?): RemoteText {
            texts++
            try { textGate?.await() } catch (failure: CancellationException) { cancelledTexts++; throw failure }
            return RemoteText(episodeId, 1, "Text for a shortcut.", null, 5)
        }
        override suspend fun save(token: String, episodeId: Int?, url: String?) = first
        override suspend fun remove(token: String, episodeId: Int) {}
        override suspend fun played(token: String, episodeId: Int, played: Boolean) {}
        override suspend fun clearLatest(token: String) {}
        override suspend fun subscribe(token: String, url: String) = feeds(token).first()
        override suspend fun position(token: String, episodeId: Int, seconds: Double, completed: Boolean) {}
    }
    @Before fun prepare() {
        InstrumentationRegistry.getInstrumentation().uiAutomation.grantRuntimePermission(app.packageName, Manifest.permission.RECORD_AUDIO)
        app.stopService(Intent(app, PlaybackService::class.java))
        api = Api(); library = AccountLibrary(api, "https://shortcuts-fixture.invalid")
        runBlocking(Dispatchers.Main) { library.changeSession("one") }
        PreviewStore(app).saveContinuation(owner, null)
        app.libraryOverride = library
        app.voiceInputOverride = object : VoiceInput {
            override suspend fun listen(firstWordsMs: Long, onReady: () -> Unit, onPartial: (String) -> Unit): String? {
                listens++; microphoneActive = true
                try { onReady(); awaitCancellation() } finally { microphoneActive = false }
            }
            override fun finish() {}
        }
        scenario = ActivityScenario.launch(MainActivity::class.java)
        scenario!!.onActivity { model = ViewModelProvider(it)[MagpieModel::class.java]; launchIntent = Intent(it.intent) }
        compose.waitUntil(10_000) { model.player.value.connected }
    }
    @After fun finish() {
        if (::model.isInitialized) compose.runOnUiThread { model.cancelShortcut(); model.voice.close(false); model.dismissPlayer() }
        // ActivityScenario matches data URI and categories when tracking lifecycle
        // events. Restore its launch identity only after testing the real handoff.
        scenario?.onActivity { it.intent = Intent(launchIntent) }
        scenario?.close()
        externalActivity?.let { activity -> compose.runOnUiThread { activity.finishAndRemoveTask() } }
        app.stopService(Intent(app, PlaybackService::class.java))
        app.libraryOverride = null; app.voiceInputOverride = null
        PreviewStore(app).saveContinuation(library.state.value.owner, null)
    }
    private fun deliver(request: ShortcutRequest) {
        // ActivityScenario filters lifecycle events by the original launch category.
        scenario!!.onActivity { it.startActivity(MagpieShortcuts.intent(it, request).addCategory(Intent.CATEGORY_LAUNCHER)) }
    }
    private fun waitPlaying(id: Int) = compose.waitUntil(15_000) { model.player.value.playing && model.player.value.item?.episodeId == id }
    private fun waitIdle() = compose.waitUntil(10_000) { model.shortcutWorking.value == null }
    @androidx.annotation.RequiresApi(36)
    private fun assistantAction(id: String, name: String, value: String): PendingIntent = runBlocking {
        Assume.assumeTrue("Requires the current AppFunctions metadata indexer",
            android.os.Build.VERSION.SDK_INT_FULL >= android.os.Build.VERSION_CODES_FULL.BAKLAVA_1)
        val manager = checkNotNull(AppFunctionManager.getInstance(app))
        withTimeout(60_000) {
            while (true) {
                try { manager.setAppFunctionEnabled(id, AppFunctionManager.APP_FUNCTION_STATE_ENABLED); break }
                catch (_: IllegalArgumentException) { delay(500) }
            }
        }
        val metadata = manager.searchAppFunctions(AppFunctionSearchSpec(packageNames = setOf(app.packageName))).first { it.id == id }
        val result = manager.executeAppFunction(ExecuteAppFunctionRequest(app.packageName, id,
            AppFunctionData.Builder(metadata.parameters, metadata.components).setString(name, value).build()))
        assertTrue(result.toString(), result is ExecuteAppFunctionResponse.Success)
        (result as ExecuteAppFunctionResponse.Success).returnValue
            .getAppFunctionData(ExecuteAppFunctionResponse.Success.PROPERTY_RETURN_VALUE)!!.getParcelable("openMagpie", android.app.PendingIntent::class.java)!!
    }
    @androidx.annotation.RequiresApi(36)
    private fun open(action: PendingIntent) {
        assertTrue(action.isImmutable)
        compose.runOnUiThread { action.send() }
    }
    private fun shell(command: String): String =
        android.os.ParcelFileDescriptor.AutoCloseInputStream(InstrumentationRegistry.getInstrumentation().uiAutomation.executeShellCommand(command)).use { it.readBytes().toString(Charsets.UTF_8).trim() }

    @Test fun aColdActivityLaunchConsumesTheShortcutAndStartsTheRequestedItem() {
        scenario!!.close(); scenario = null
        compose.runOnUiThread { app.startActivity(MagpieShortcuts.intent(app, ShortcutRequest(ShortcutAction.Latest))) }
        compose.waitUntil(10_000) {
            InstrumentationRegistry.getInstrumentation().runOnMainSync {
                externalActivity = androidx.test.runner.lifecycle.ActivityLifecycleMonitorRegistry.getInstance()
                    .getActivitiesInStage(androidx.test.runner.lifecycle.Stage.RESUMED).filterIsInstance<MainActivity>().firstOrNull()
                externalActivity?.let { model = ViewModelProvider(it)[MagpieModel::class.java] }
            }
            externalActivity != null
        }
        waitPlaying(1)
        assertEquals(Intent.ACTION_MAIN, externalActivity!!.intent.action)
    }

    @Test fun launcherPublishesFourExecutableShortcutsAndUntrustedAskNeverStartsTheMicrophone() {
        val shortcuts = app.getSystemService(ShortcutManager::class.java).dynamicShortcuts
        assertEquals(4, shortcuts.size)
        assertEquals(MagpieShortcuts.basics.toSet(), shortcuts.map { MagpieShortcuts.take(app, Intent(checkNotNull(it.intent)))!!.action }.toSet())
        deliver(ShortcutRequest(ShortcutAction.Ask))
        compose.onNodeWithText("Type a request").assertIsDisplayed()
        assertEquals(0, listens)
        scenario!!.recreate(); scenario!!.onActivity { model = ViewModelProvider(it)[MagpieModel::class.java] }
        compose.onNodeWithText("Type a request").assertIsDisplayed(); assertEquals(0, listens)
        compose.onNodeWithText("Close").performClick()
        deliver(ShortcutRequest(ShortcutAction.Saved))
        compose.onNodeWithContentDescription("Add link").assertExists()
    }

    @Test fun trustedLauncherStartsListeningOnceAndStopsAcrossBackgroundAndRecreation() {
        fun launch() {
            val published = app.getSystemService(ShortcutManager::class.java).dynamicShortcuts.first { it.id == "magpie-ask" }
            scenario!!.onActivity { it.startActivity(Intent(checkNotNull(published.intent)).addCategory(Intent.CATEGORY_LAUNCHER)) }
        }
        launch()
        compose.waitUntil(10_000) { listens == 1 && microphoneActive }
        assertFalse(scenarioIntentHasProof())
        scenario!!.recreate(); scenario!!.onActivity { model = ViewModelProvider(it)[MagpieModel::class.java] }
        compose.waitUntil(5_000) { !microphoneActive }
        compose.onNodeWithText("Listen").assertIsDisplayed(); assertEquals(1, listens)
        launch(); compose.waitUntil(10_000) { listens == 2 && microphoneActive }
        scenario!!.moveToState(androidx.lifecycle.Lifecycle.State.CREATED)
        compose.waitUntil(5_000) { !microphoneActive }
        scenario!!.moveToState(androidx.lifecycle.Lifecycle.State.RESUMED)
        compose.onNodeWithText("Listen").assertIsDisplayed(); assertEquals(2, listens)
    }

    private fun scenarioIntentHasProof(): Boolean {
        var proof = false
        scenario!!.onActivity { proof = it.intent.hasExtra("shortcut_microphone") }
        return proof
    }

    @Test fun forgedProofAndOrdinaryIntentFlagsCannotAuthorizeTheMicrophone() {
        val forged = MagpieShortcuts.intent(app, ShortcutRequest(ShortcutAction.Ask, listenOnOpen = true))
            .putExtra("shortcut_microphone", "0".repeat(64)).putExtra("listenOnOpen", true)
        assertFalse(checkNotNull(MagpieShortcuts.take(app, Intent(forged))).listenOnOpen)
        scenario!!.onActivity { it.startActivity(forged.addCategory(Intent.CATEGORY_LAUNCHER)) }
        compose.onNodeWithText("Listen").assertIsDisplayed(); assertEquals(0, listens)
        val published = app.getSystemService(ShortcutManager::class.java).dynamicShortcuts.first { it.id == "magpie-ask" }
        val copied = Intent(checkNotNull(published.intent))
        assertTrue(checkNotNull(MagpieShortcuts.take(app, copied)).listenOnOpen)
        assertNull(MagpieShortcuts.take(app, copied))
        assertFalse(copied.hasExtra("shortcut_microphone"))
        val changedAction = Intent(checkNotNull(published.intent)).putExtra("shortcut_action", "Saved")
        assertFalse(checkNotNull(MagpieShortcuts.take(app, changedAction)).listenOnOpen)
    }

    @Test fun permissionDenialAndLateGrantCannotStartANewConversation() {
        var permissionGranted = false
        var requests = 0
        var permissionCode = 0
        val registry = object : ActivityResultRegistry() {
            override fun <I, O> onLaunch(requestCode: Int, contract: ActivityResultContract<I, O>, input: I, options: ActivityOptionsCompat?) {
                assertEquals(Manifest.permission.RECORD_AUDIO, input)
                permissionCode = requestCode; requests++
            }
        }
        scenario!!.onActivity { activity ->
            val permissionContext = object : android.content.ContextWrapper(activity) {
                override fun checkSelfPermission(permission: String): Int =
                    if (permission == Manifest.permission.RECORD_AUDIO && !permissionGranted) PackageManager.PERMISSION_DENIED else super.checkSelfPermission(permission)
            }
            activity.setContent {
                CompositionLocalProvider(LocalContext provides permissionContext,
                    LocalActivityResultRegistryOwner provides object : ActivityResultRegistryOwner { override val activityResultRegistry = registry }) {
                    MagpieTheme { AskConversation(model) }
                }
            }
        }
        compose.runOnUiThread { model.voice.open(null, listenOnOpen = true) }
        compose.waitUntil(5_000) { requests == 1 }; assertEquals(0, listens)
        compose.runOnUiThread { registry.dispatchResult(permissionCode, false) }
        compose.onNodeWithText("Microphone access is off.", substring = true).assertExists(); assertEquals(0, listens)
        compose.onNodeWithText("Listen").performClick()
        compose.waitUntil(5_000) { requests == 2 }
        compose.runOnUiThread {
            model.voice.background(); model.voice.open(null)
            permissionGranted = true; registry.dispatchResult(permissionCode, true)
        }
        compose.onNodeWithText("Listen").assertIsDisplayed(); assertEquals(0, listens)
        compose.runOnUiThread { permissionGranted = false }
        compose.onNodeWithText("Listen").performClick()
        compose.waitUntil(5_000) { requests == 3 }
        compose.runOnUiThread { permissionGranted = true; registry.dispatchResult(permissionCode, true) }
        compose.waitUntil(10_000) { listens == 1 && microphoneActive }
    }

    @Test fun latestRunsOnceAcrossRecreationAndAcceptsAnotherExplicitDelivery() {
        val calls = api.latestCalls
        deliver(ShortcutRequest(ShortcutAction.Latest)); waitPlaying(1)
        assertEquals(calls + 1, api.latestCalls)
        compose.runOnUiThread { model.pause() }
        compose.waitUntil(5_000) { !model.player.value.playing }
        scenario!!.recreate(); scenario!!.onActivity { model = ViewModelProvider(it)[MagpieModel::class.java] }
        compose.waitForIdle(); assertFalse(model.player.value.playing); assertEquals(calls + 1, api.latestCalls)
        deliver(ShortcutRequest(ShortcutAction.Latest)); waitPlaying(1)
        assertEquals(calls + 2, api.latestCalls)
    }

    @Test fun continuationResolvesAnOlderItemFromDiskInTheCorrectAccount() {
        PreviewStore(app).saveContinuation(owner, "$owner:episode:7")
        assertEquals("$owner:episode:7", PreviewStore(app).continuation(owner))
        deliver(ShortcutRequest(ShortcutAction.Continue)); waitPlaying(7)
        assertEquals(1, api.episodeCalls)
        assertTrue(model.player.value.positionMs >= 18_000)
        compose.runOnUiThread { model.dismissPlayer() }
        compose.waitUntil(5_000) { model.player.value.item == null }
        assertEquals("$owner:episode:7", PreviewStore(app).continuation(owner))
        deliver(ShortcutRequest(ShortcutAction.Continue)); waitPlaying(7)
    }

    @Test fun continueKeepsTheLoadedPlayersNewerPosition() {
        deliver(ShortcutRequest(ShortcutAction.Latest)); waitPlaying(1)
        compose.waitUntil(5_000) { model.player.value.durationMs > 30_000 }
        compose.runOnUiThread { model.seek(25_000) }
        compose.waitUntil(5_000) { model.player.value.positionMs >= 25_000 }
        compose.runOnUiThread { model.pause() }
        compose.waitUntil(5_000) { !model.player.value.playing }
        deliver(ShortcutRequest(ShortcutAction.Continue)); waitPlaying(1)
        assertTrue(model.player.value.positionMs >= 25_000); assertEquals(0, api.episodeCalls)
    }

    @Test fun pinnedShowAndItemResolveAgainstCurrentLibrary() {
        deliver(ShortcutRequest(ShortcutAction.PlayFeed, owner, feedId = "10")); waitPlaying(2)
        deliver(ShortcutRequest(ShortcutAction.ReadItem, owner, "$owner:episode:7")); waitIdle()
        compose.onNodeWithContentDescription("Find in this page").assertExists()
        assertEquals(1, api.episodeCalls)
        assertEquals(2, model.player.value.item?.episodeId)
        deliver(ShortcutRequest(ShortcutAction.PlayItem, owner, "$owner:episode:7")); waitPlaying(7)
    }

    @Test @SdkSuppress(minSdkVersion = 36)
    fun assistantDestinationsOpenTheRequestedScreensWithoutStartingAudioOrMicrophone() {
        fun destination(name: String) = assistantAction(MagpieAppFunctions.FUNCTION_ID_OPEN_MAGPIE_DESTINATION, "destination", name)
        val latest = destination("latest")
        open(latest)
        compose.onNodeWithContentDescription("Clear Latest").assertExists()
        try { latest.send(); fail("A destination action must be one-use") } catch (_: PendingIntent.CanceledException) {}
        open(destination("following")); compose.onNodeWithTag("following-list").assertExists()
        open(destination("saved")); compose.onNodeWithContentDescription("Add link").assertExists()
        open(destination("shortcuts")); compose.onNodeWithTag("shortcuts-list").assertExists()
        compose.onNodeWithContentDescription("Back").performClick()
        assertFalse(model.player.value.playing); assertEquals(0, listens)
        deliver(ShortcutRequest(ShortcutAction.Latest)); waitPlaying(1)
        val before = model.player.value.positionMs
        open(destination("nowPlaying")); compose.onNodeWithContentDescription("Close player").assertExists()
        assertTrue(model.player.value.playing); assertEquals(1, model.player.value.item?.episodeId)
        assertTrue(model.player.value.positionMs >= before); assertEquals(0, listens)
    }

    @Test @SdkSuppress(minSdkVersion = 36)
    fun assistantItemAndShowLinksOpenTheirContentAndPreserveTheCurrentPlayer() {
        deliver(ShortcutRequest(ShortcutAction.Latest)); waitPlaying(1)
        val show = assistantAction(MagpieAppFunctions.FUNCTION_ID_OPEN_FOLLOWED_SHOW, "showId", "$owner:feed:10")
        open(show)
        compose.onNodeWithContentDescription("Back").assertExists()
        compose.onNodeWithTag("story-list").assertExists()
        compose.onNodeWithText("Shortcut second podcast").assertExists()
        val item = assistantAction(MagpieAppFunctions.FUNCTION_ID_OPEN_LISTENING_ITEM, "itemId", "$owner:episode:7")
        open(item)
        compose.onNodeWithContentDescription("Find in this page").assertExists()
        assertTrue(model.player.value.playing); assertEquals(1, model.player.value.item?.episodeId)
        assertEquals(0, listens)
    }

    @Test @SdkSuppress(minSdkVersion = 36)
    fun delayedAssistantLinksRejectChangedAccountsAndRemovedShows() {
        val old = assistantAction(MagpieAppFunctions.FUNCTION_ID_OPEN_MAGPIE_DESTINATION, "destination", "shortcuts")
        runBlocking(Dispatchers.Main) { library.changeSession("two") }
        val calls = api.episodeCalls
        open(old)
        compose.onNodeWithText("another account", substring = true).assertExists()
        compose.onNodeWithTag("shortcuts-list").assertDoesNotExist()
        assertEquals(calls, api.episodeCalls)
        val show = assistantAction(MagpieAppFunctions.FUNCTION_ID_OPEN_FOLLOWED_SHOW, "showId", "$owner:feed:10")
        api.following = false
        runBlocking(Dispatchers.Main) { library.refresh() }
        open(show)
        compose.onNodeWithText("no longer followed", substring = true).assertExists()
        compose.onNodeWithTag("following-list").assertExists()
        assertFalse(model.player.value.playing); assertEquals(0, listens)
    }

    @Test fun aDifferentAccountsPinnedItemNeverQueriesOrPlays() {
        val another = "a".repeat(64)
        deliver(ShortcutRequest(ShortcutAction.PlayItem, another, "$another:episode:7"))
        compose.waitUntil(5_000) { model.notice.value?.contains("another account") == true }
        assertEquals(0, api.episodeCalls); assertFalse(model.player.value.playing)
    }

    @Test fun queuedNavigationRechecksTheAccountAndShowBeforeTheScreenConsumesIt() {
        fun holdRoute(request: ShortcutRequest) {
            scenario!!.onActivity { it.setContent { androidx.compose.material3.Text("Waiting to display navigation") } }
            compose.waitForIdle()
            compose.runOnUiThread { model.runShortcut(request) }
            compose.waitUntil(5_000) { model.shortcutNavigation.value != null }
        }
        fun display() {
            scenario!!.onActivity { it.setContent { MagpieTheme { MagpieApp(model) } } }
            compose.waitUntil(5_000) { model.shortcutNavigation.value == null }
        }
        holdRoute(ShortcutRequest(ShortcutAction.Shortcuts, owner))
        runBlocking(Dispatchers.Main) { library.changeSession("two") }
        display()
        compose.onNodeWithTag("shortcuts-list").assertDoesNotExist()
        compose.onNodeWithTag("following-list").assertExists()
        holdRoute(ShortcutRequest(ShortcutAction.OpenFeed, owner, feedId = "10"))
        api.following = false
        runBlocking(Dispatchers.Main) { library.refresh() }
        display()
        compose.onNodeWithTag("following-list").assertExists()
        compose.onNodeWithTag("story-list").assertDoesNotExist()
        assertFalse(model.player.value.playing); assertEquals(0, listens)
    }

    @Test fun accountChangeDuringLookupDiscardsTheLateItem() {
        api.episodeGate = CompletableDeferred()
        val oldOwner = owner
        deliver(ShortcutRequest(ShortcutAction.PlayItem, oldOwner, "$oldOwner:episode:7"))
        compose.waitUntil(5_000) { api.episodeCalls == 1 }
        runBlocking(Dispatchers.Main) { library.changeSession("two") }
        api.episodeGate!!.complete(Unit); waitIdle()
        assertFalse(model.player.value.playing)
        assertTrue(library.state.value.items.none { it.id.startsWith(oldOwner) })
    }

    @Test fun aValidatedShortcutCancelsEarlierContentPreparationBeforeWaitingForItsOwnLookup() {
        api.latestRows += api.first.copy(id = 8, title = "Pending reading", audioUrl = null, contentId = 1)
        runBlocking(Dispatchers.Main) { library.refresh() }
        api.textGate = CompletableDeferred(); api.episodeGate = CompletableDeferred()
        compose.runOnUiThread { model.play(model.library.first { it.episodeId == 8 }) }
        compose.waitUntil(5_000) { api.texts == 1 }
        deliver(ShortcutRequest(ShortcutAction.ReadItem, owner, "$owner:episode:7"))
        compose.waitUntil(5_000) { api.episodeCalls == 1 && api.cancelledTexts == 1 }
        api.textGate!!.complete(Unit)
        assertFalse(model.player.value.playing)
        api.episodeGate!!.complete(Unit); waitIdle()
        compose.onNodeWithContentDescription("Find in this page").assertExists()
        assertFalse(model.player.value.playing)
    }

    @Test fun explicitExternalPauseInvalidatesAPendingPlaybackShortcut() {
        api.episodeGate = CompletableDeferred()
        deliver(ShortcutRequest(ShortcutAction.PlayItem, owner, "$owner:episode:7"))
        compose.waitUntil(5_000) { api.episodeCalls == 1 }
        val future = MediaController.Builder(app, SessionToken(app, ComponentName(app, PlaybackService::class.java))).buildAsync()
        val control = future.get(10, TimeUnit.SECONDS)
        val before = com.henrydashwood.magpie.playback.PlaybackStatus.controlVersion.value
        compose.runOnUiThread { control.pause() }
        compose.waitUntil(5_000) { com.henrydashwood.magpie.playback.PlaybackStatus.controlVersion.value != before }
        api.episodeGate!!.complete(Unit); waitIdle(); assertFalse(model.player.value.playing)
        compose.runOnUiThread { control.release() }
    }

    @Test fun cancellingLookupAndInvalidIntentCannotStartPlaybackLater() {
        api.episodeGate = CompletableDeferred()
        deliver(ShortcutRequest(ShortcutAction.PlayItem, owner, "$owner:episode:7"))
        compose.waitUntil(5_000) { api.episodeCalls == 1 }
        compose.onNodeWithText("Cancel").performClick(); api.episodeGate!!.complete(Unit)
        waitIdle(); assertFalse(model.player.value.playing)
        val malformed = MagpieShortcuts.intent(app, ShortcutRequest(ShortcutAction.PlayItem)).putExtra("shortcut_item", "x".repeat(200))
        assertNull(MagpieShortcuts.take(app, malformed)); assertEquals(Intent.ACTION_MAIN, malformed.action)
        val ai = MagpieShortcuts.intent(app, ShortcutRequest(ShortcutAction.Ask)).putExtra("shortcut_action", "SendTranscript").putExtra("transcript", "Play anything")
        assertNull(MagpieShortcuts.take(app, ai)); assertEquals(0, listens)
    }

    @Test fun emptyLatestAndNoContinuationExplainHowToProceed() {
        PreviewStore(app).lastItem = null
        deliver(ShortcutRequest(ShortcutAction.Continue))
        compose.waitUntil(5_000) { model.notice.value?.contains("nothing to continue") == true }
        api.latestRows = emptyList()
        deliver(ShortcutRequest(ShortcutAction.Latest))
        compose.waitUntil(5_000) { model.notice.value?.contains("nothing new") == true }
        assertFalse(model.player.value.playing)
    }

    @Test fun actualQuickSettingsTileStartsTheTrustedMicrophoneLaunch() {
        val component = ComponentName(app, AskMagpieTile::class.java)
        val info = app.packageManager.getServiceInfo(component, PackageManager.ComponentInfoFlags.of(0))
        assertEquals("android.permission.BIND_QUICK_SETTINGS_TILE", info.permission); assertTrue(info.exported)
        val originalTiles = shell("settings get secure sysui_qs_tiles")
        // UiAutomation passes whitespace-delimited arguments directly, not through a shell.
        require(originalTiles.matches(Regex("[A-Za-z0-9_.,/()$-]+")))
        try {
            // Keep the fixture tile visible; a tile on an unopened page is not bound by SystemUI.
            shell("cmd statusbar set-tiles custom(${component.flattenToString()})")
            shell("cmd statusbar expand-settings")
            compose.waitUntil(10_000) { shell("dumpsys activity services ${app.packageName}").contains("AskMagpieTile") }
            shell("cmd statusbar click-tile ${component.flattenToString()}")
            compose.waitUntil(10_000) { model.voice.state.value.visible }
            compose.onNodeWithText("Type a request").assertIsDisplayed()
            compose.waitUntil(10_000) { listens == 1 && microphoneActive }
        } finally {
            shell("cmd statusbar collapse")
            shell("cmd statusbar set-tiles $originalTiles")
            scenario!!.onActivity { it.intent.addCategory(Intent.CATEGORY_LAUNCHER) }
        }
    }

    @Test fun theLauncherCanPinAnAccountBoundItemAfterSystemConfirmation() {
        val manager = app.getSystemService(ShortcutManager::class.java)
        val request = ShortcutRequest(ShortcutAction.PlayItem, owner, "$owner:episode:7")
        compose.runOnUiThread { assertTrue(MagpieShortcuts.pin(app, request, "Test older episode")) }
        var confirmed = false
        compose.waitUntil(10_000) {
            if (!confirmed) {
                val root = InstrumentationRegistry.getInstrumentation().uiAutomation.rootInActiveWindow
                val add = root?.findAccessibilityNodeInfosByText("Add")?.firstOrNull { it.isClickable && it.isEnabled }
                if (add != null) confirmed = add.performAction(android.view.accessibility.AccessibilityNodeInfo.ACTION_CLICK)
            }
            manager.pinnedShortcuts.any { shortcut ->
                MagpieShortcuts.take(app, Intent(checkNotNull(shortcut.intent)))?.let { it.owner == owner && it.itemId == request.itemId } == true
            }
        }
        val pinned = manager.pinnedShortcuts.first { MagpieShortcuts.take(app, Intent(checkNotNull(it.intent)))?.itemId == request.itemId }
        val delivered = checkNotNull(MagpieShortcuts.take(app, Intent(checkNotNull(pinned.intent))))
        assertEquals(owner, delivered.owner)
        // The instrumentation install is removed by Gradle, including this fixture's home-screen pin.
        deliver(delivered); waitPlaying(7)
    }

    @Test fun shortcutControlsAndPickerRemainScrollableAtLargeTextInDarkMode() {
        compose.runOnUiThread { model.runShortcut(ShortcutRequest(ShortcutAction.Shortcuts)) }
        compose.onNodeWithText("Assistant and Shortcuts").assertExists()
        scenario!!.recreate(); scenario!!.onActivity { model = ViewModelProvider(it)[MagpieModel::class.java] }
        compose.onNodeWithText("Assistant and Shortcuts").assertExists()
        scenario!!.onActivity { activity ->
            activity.setContent { CompositionLocalProvider(LocalDensity provides Density(activity.resources.displayMetrics.density, 2f)) {
                MagpieTheme(darkTheme = true) { MagpieApp(model) }
            } }
        }
        compose.runOnUiThread { model.runShortcut(ShortcutRequest(ShortcutAction.Shortcuts)) }
        compose.onNodeWithTag("shortcuts-list").performScrollToNode(hasText("Add Continue listening tile"))
        compose.onNodeWithText("Add Continue listening tile").assertIsDisplayed()
        val directory = InstrumentationRegistry.getArguments().getString("additionalTestOutputDir")
        if (directory != null) File(directory, "shortcuts-large-dark.png").outputStream().use {
            InstrumentationRegistry.getInstrumentation().uiAutomation.takeScreenshot().compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it)
        }
        compose.onNodeWithTag("shortcuts-list").performScrollToNode(hasText("Add an item shortcut"))
        compose.onNodeWithText("Add an item shortcut").performClick()
        compose.onNodeWithText("Choose an item").assertIsDisplayed()
        compose.onNodeWithText("Cancel").performClick()
    }
}
