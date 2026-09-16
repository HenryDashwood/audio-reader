package com.henrydashwood.magpie

import android.content.ComponentName
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ShortcutManager
import androidx.activity.compose.setContent
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.platform.LocalDensity
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
    private var scenario: ActivityScenario<MainActivity>? = null
    private var externalActivity: MainActivity? = null
    private var listens = 0
    private val owner get() = checkNotNull(library.state.value.owner)
    private class Api : LibraryApi {
        val first = RemoteEpisode(1, "Shortcut first podcast", source = "Shortcut show", feedUrl = "https://fixture.invalid/feed", audioUrl = "asset:///welcome.wav", positionSeconds = 12.0)
        val second = first.copy(id = 2, title = "Shortcut second podcast", positionSeconds = 0.0)
        val hidden = first.copy(id = 7, title = "An older episode", positionSeconds = 18.0)
        var latestCalls = 0
        var episodeCalls = 0
        var episodeGate: CompletableDeferred<Unit>? = null
        var latestRows = listOf(first, second)
        override suspend fun userId(token: String) = "shortcut-user-$token"
        override suspend fun feeds(token: String) = listOf(LibraryFeed("10", "Shortcut show", 2, false, "https://fixture.invalid/feed"))
        override suspend fun latest(token: String): List<RemoteEpisode> { latestCalls++; return latestRows }
        override suspend fun saved(token: String) = emptyList<RemoteEpisode>()
        override suspend fun episodes(token: String, feedId: String, query: String) = listOf(second)
        override suspend fun search(token: String, query: String) = emptyList<RemoteEpisode>()
        override suspend fun episode(token: String, episodeId: Int): RemoteEpisode {
            episodeCalls++; episodeGate?.await()
            return listOf(first, second, hidden).first { it.id == episodeId }
        }
        override suspend fun text(token: String, episodeId: Int, contentId: Int?) = RemoteText(episodeId, 1, "Text for a shortcut.", null, 5)
        override suspend fun save(token: String, episodeId: Int?, url: String?) = first
        override suspend fun remove(token: String, episodeId: Int) {}
        override suspend fun played(token: String, episodeId: Int, played: Boolean) {}
        override suspend fun clearLatest(token: String) {}
        override suspend fun subscribe(token: String, url: String) = feeds(token).first()
        override suspend fun position(token: String, episodeId: Int, seconds: Double, completed: Boolean) {}
    }
    @Before fun prepare() {
        app.stopService(Intent(app, PlaybackService::class.java))
        api = Api(); library = AccountLibrary(api, "https://shortcuts-fixture.invalid")
        runBlocking(Dispatchers.Main) { library.changeSession("one") }
        PreviewStore(app).saveContinuation(owner, null)
        app.libraryOverride = library
        app.voiceInputOverride = object : VoiceInput {
            override suspend fun listen(firstWordsMs: Long, onReady: () -> Unit, onPartial: (String) -> Unit): String? { listens++; awaitCancellation() }
            override fun finish() {}
        }
        scenario = ActivityScenario.launch(MainActivity::class.java)
        scenario!!.onActivity { model = ViewModelProvider(it)[MagpieModel::class.java] }
        compose.waitUntil(10_000) { model.player.value.connected }
    }
    @After fun finish() {
        if (::model.isInitialized) compose.runOnUiThread { model.cancelShortcut(); model.voice.close(false); model.dismissPlayer() }
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

    @Test fun launcherPublishesFourExecutableShortcutsAndAskNeverStartsTheMicrophone() {
        val shortcuts = app.getSystemService(ShortcutManager::class.java).dynamicShortcuts
        assertEquals(4, shortcuts.size)
        assertEquals(MagpieShortcuts.basics.toSet(), shortcuts.map { MagpieShortcuts.take(Intent(checkNotNull(it.intent)))!!.action }.toSet())
        deliver(ShortcutRequest(ShortcutAction.Ask))
        compose.onNodeWithText("Type a request").assertIsDisplayed()
        assertEquals(0, listens)
        scenario!!.recreate(); scenario!!.onActivity { model = ViewModelProvider(it)[MagpieModel::class.java] }
        compose.onNodeWithText("Type a request").assertIsDisplayed(); assertEquals(0, listens)
        compose.onNodeWithText("Close").performClick()
        deliver(ShortcutRequest(ShortcutAction.Saved))
        compose.onNodeWithContentDescription("Add link").assertExists()
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

    @Test fun aDifferentAccountsPinnedItemNeverQueriesOrPlays() {
        val another = "a".repeat(64)
        deliver(ShortcutRequest(ShortcutAction.PlayItem, another, "$another:episode:7"))
        compose.waitUntil(5_000) { model.notice.value?.contains("another account") == true }
        assertEquals(0, api.episodeCalls); assertFalse(model.player.value.playing)
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
        assertNull(MagpieShortcuts.take(malformed)); assertEquals(Intent.ACTION_MAIN, malformed.action)
        val ai = MagpieShortcuts.intent(app, ShortcutRequest(ShortcutAction.Ask)).putExtra("shortcut_action", "SendTranscript").putExtra("transcript", "Play anything")
        assertNull(MagpieShortcuts.take(ai)); assertEquals(0, listens)
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

    @Test fun actualQuickSettingsTileOpensAskWithoutRecording() {
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
            compose.onNodeWithText("Type a request").assertIsDisplayed(); assertEquals(0, listens)
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
                MagpieShortcuts.take(Intent(checkNotNull(shortcut.intent)))?.let { it.owner == owner && it.itemId == request.itemId } == true
            }
        }
        val pinned = manager.pinnedShortcuts.first { MagpieShortcuts.take(Intent(checkNotNull(it.intent)))?.itemId == request.itemId }
        val delivered = checkNotNull(MagpieShortcuts.take(Intent(checkNotNull(pinned.intent))))
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
