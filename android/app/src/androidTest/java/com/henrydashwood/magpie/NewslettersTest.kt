package com.henrydashwood.magpie

import android.content.ClipboardManager
import android.content.Intent
import androidx.activity.compose.setContent
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Density
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.lifecycle.ViewModelProvider
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import androidx.test.platform.app.InstrumentationRegistry
import com.henrydashwood.magpie.data.*
import com.henrydashwood.magpie.playback.PlaybackService
import com.henrydashwood.magpie.ui.MagpieApp
import com.henrydashwood.magpie.ui.MagpieTheme
import com.henrydashwood.magpie.voice.*
import kotlinx.coroutines.*
import org.junit.*
import org.junit.Assert.*
import java.io.File

class NewslettersTest {
    @get:Rule val compose = createEmptyComposeRule()
    private val app get() = ApplicationProvider.getApplicationContext<MagpieTestApplication>()
    private lateinit var api: Api
    private lateinit var library: AccountLibrary
    private lateinit var model: MagpieModel
    private var scenario: ActivityScenario<MainActivity>? = null
    private val spoken = mutableListOf<String>()
    private class Api : LibraryApi, NewsletterApi, DiscoveryApi {
        var approved = false
        var blocked = false
        var signups = 0
        val feed = LibraryFeed("30", "Morning news", 2, true)
        override suspend fun newsletterAddress(token: String) = NewsletterAddress("quiet-$token@magpie.example")
        override suspend fun pendingNewsletters(token: String) = buildList {
            if (!approved) add(PendingNewsletter(30, "Morning news", "editor@example.com", 2, "Today's news"))
            if (!blocked) add(PendingNewsletter(31, "Garden notes", "gardener@example.com", 1, "Growing tomatoes"))
        }
        override suspend fun approveNewsletter(token: String, feedId: Int): LibraryFeed { approved = true; return feed }
        override suspend fun blockNewsletter(token: String, feedId: Int) { blocked = true }
        override suspend fun signUpForNewsletter(token: String, url: String): NewsletterSignup {
            signups++; return NewsletterSignup("unsupported", "Use this address on the website to finish signing up.", "quiet-$token@magpie.example", "Example publication", reason = "captcha")
        }
        override suspend fun userId(token: String) = token
        override suspend fun feeds(token: String) = if (approved) listOf(feed) else emptyList()
        override suspend fun latest(token: String) = if (approved) listOf(RemoteEpisode(1, "Today's news", contentId = 1)) else emptyList()
        override suspend fun saved(token: String) = emptyList<RemoteEpisode>()
        override suspend fun episodes(token: String, feedId: String, query: String) = latest(token)
        override suspend fun search(token: String, query: String) = emptyList<RemoteEpisode>()
        override suspend fun text(token: String, episodeId: Int, contentId: Int?) = RemoteText(1, 1, "The morning news.", null, 3)
        override suspend fun save(token: String, episodeId: Int?, url: String?): RemoteEpisode = error("Not used")
        override suspend fun remove(token: String, episodeId: Int) {}
        override suspend fun played(token: String, episodeId: Int, played: Boolean) {}
        override suspend fun clearLatest(token: String) {}
        override suspend fun subscribe(token: String, url: String): LibraryFeed = error("Must not subscribe to a feed")
        override suspend fun position(token: String, episodeId: Int, seconds: Double, completed: Boolean) {}
        override suspend fun directory(token: String, query: String) = emptyList<SourceResult>()
        override suspend fun discover(token: String, url: String) = emptyList<SourceResult>()
        override suspend fun preview(token: String, url: String): RemotePreview = error("Not used")
        override suspend fun webSearch(token: String, query: String): SourceResult? = error("Must not use AI")
        override suspend fun aiConsent(token: String) = false
        override suspend fun setAIConsent(token: String, granted: Boolean): Boolean = error("Must not grant AI")
    }
    @Before fun prepare() {
        app.stopService(Intent(app, PlaybackService::class.java))
        api = Api(); library = AccountLibrary(api, "https://newsletter-fixture.invalid")
        runBlocking(Dispatchers.Main) { library.changeSession("heron") }
        app.libraryOverride = library
        app.voiceOutputOverride = VoiceOutput { spoken += it }
        app.voiceInputOverride = object : VoiceInput {
            override suspend fun listen(firstWordsMs: Long, onReady: () -> Unit, onPartial: (String) -> Unit): String? = error("Address must never start capture")
            override fun finish() {}
        }
        scenario = ActivityScenario.launch(MainActivity::class.java)
        scenario!!.onActivity { model = ViewModelProvider(it)[MagpieModel::class.java] }
        compose.waitUntil(10_000) { model.newsletters.state.value.pending.size == 2 }
    }
    @After fun finish() {
        scenario?.onActivity { model.newsletterSpeech.stop(resume = false) }
        scenario?.close(); app.stopService(Intent(app, PlaybackService::class.java))
        app.libraryOverride = null; app.voiceInputOverride = null; app.voiceOutputOverride = null
    }
    private fun setting(text: String) = compose.onNodeWithTag("settings-list").performScrollToNode(hasText(text))
    private fun capture(name: String) {
        // Android's clipboard overlay can outlive the preceding test's activity.
        // Let its normal display timeout finish before capturing app layout.
        compose.waitForIdle()
        Thread.sleep(7_000)
        compose.waitForIdle()
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val bitmap = checkNotNull(instrumentation.uiAutomation.takeScreenshot())
        val output = InstrumentationRegistry.getArguments().getString("additionalTestOutputDir")?.let(::File) ?: File(app.filesDir, "screenshots")
        output.mkdirs()
        File(output, "$name.png").outputStream().use { bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it) }
    }
    @Test fun followUpdatesLatestAndBlockingRequiresConfirmation() {
        compose.onNodeWithContentDescription("Follow Morning news").performClick()
        compose.waitUntil(10_000) { api.approved && library.state.value.latestIds.isNotEmpty() }
        compose.onNodeWithText("Latest").performClick()
        compose.onNodeWithTag("story-list").performScrollToNode(hasText("Today's news"))
        compose.onNodeWithText("Today's news").assertIsDisplayed()
        compose.onNodeWithTag("story-list").performScrollToNode(hasContentDescription("Block Garden notes"))
        compose.onNodeWithContentDescription("Block Garden notes").performClick()
        assertFalse(api.blocked)
        compose.onNodeWithText("Cancel").performClick(); assertFalse(api.blocked)
        compose.onNodeWithContentDescription("Block Garden notes").performClick()
        compose.onNodeWithText("Block Garden notes").performClick()
        compose.waitUntil(10_000) { api.blocked && model.newsletters.state.value.pending.isEmpty() }
        assertFalse(model.player.value.playing)
    }
    @Test fun addressCanBeCopiedReadSpelledAndIsRemovedWhenTheAccountChanges() {
        compose.onNodeWithText("Settings").performClick()
        setting("Newsletters")
        compose.waitUntil(10_000) { model.newsletters.state.value.address != null && model.player.value.connected }
        setting("Copy address"); compose.onNodeWithText("Copy address").performClick()
        compose.onNodeWithText("Address copied").assertIsDisplayed()
        assertEquals("quiet-heron@magpie.example", app.getSystemService(ClipboardManager::class.java).primaryClip!!.getItemAt(0).text.toString())
        setting("Read address aloud"); compose.onNodeWithText("Read address aloud").performClick()
        compose.waitUntil(10_000) { spoken.size == 1 && !model.newsletterSpeech.speaking.value }
        setting("Spell address"); compose.onNodeWithText("Spell address").performClick()
        compose.waitUntil(10_000) { spoken.size == 2 && !model.newsletterSpeech.speaking.value }
        assertTrue(spoken.first().contains("with hyphens between")); assertTrue(spoken.last().contains("q, u, i, e, t"))
        runBlocking(Dispatchers.Main) { library.changeSession(null) }
        setting("Sign in to get your Magpie newsletter address.")
        compose.onNodeWithTag("newsletter-address").assertDoesNotExist()
        assertNull(model.newsletters.state.value.address)
    }
    @Test fun failedFeedDiscoveryOffersExplicitEmailSignupAndManualAddressCopy() {
        compose.onNodeWithContentDescription("Add sources").performClick()
        compose.onNodeWithTag("source-query").performTextInput("https://publisher.example")
        compose.onNodeWithText("Find feeds").performClick()
        compose.waitUntil(10_000) { model.discovery.state.value.error != null }
        assertEquals(0, api.signups)
        compose.onNodeWithText("Sign up by email").performClick()
        compose.waitUntil(10_000) { model.discovery.state.value.signup != null }
        compose.onNodeWithText("Needs signing up by hand").assertIsDisplayed()
        compose.onNodeWithText("Copy address").performClick()
        assertEquals(1, api.signups)
        assertEquals("quiet-heron@magpie.example", app.getSystemService(ClipboardManager::class.java).primaryClip!!.getItemAt(0).text.toString())
        capture("newsletter-signup")
    }
    @Test fun sharingOffersTheCurrentAddressToAndroidWithoutChoosingARecipient() {
        compose.onNodeWithText("Settings").performClick(); setting("Newsletters")
        compose.waitUntil(10_000) { model.newsletters.state.value.address != null }
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        var sent: Intent? = null
        val monitor = object : android.app.Instrumentation.ActivityMonitor() {
            override fun onStartActivity(intent: Intent): android.app.Instrumentation.ActivityResult? {
                if (intent.action != Intent.ACTION_CHOOSER) return null
                sent = androidx.core.content.IntentCompat.getParcelableExtra(intent, Intent.EXTRA_INTENT, Intent::class.java)
                return android.app.Instrumentation.ActivityResult(android.app.Activity.RESULT_CANCELED, null)
            }
        }
        instrumentation.addMonitor(monitor)
        try {
            setting("Share address"); compose.onNodeWithText("Share address").performClick()
            compose.waitUntil(10_000) { sent != null }
            assertEquals(Intent.ACTION_SEND, sent!!.action); assertEquals("text/plain", sent!!.type)
            assertEquals("quiet-heron@magpie.example", sent!!.getStringExtra(Intent.EXTRA_TEXT))
            assertNull(sent!!.component); assertNull(sent!!.getStringArrayExtra(Intent.EXTRA_EMAIL))
        } finally { instrumentation.removeMonitor(monitor) }
    }
    @Test fun newsletterControlsRemainReachableAtDoubleTextSizeInDarkMode() {
        scenario!!.onActivity { activity -> activity.setContent {
            val density = LocalDensity.current
            CompositionLocalProvider(LocalDensity provides Density(density.density, 2f)) { MagpieTheme(darkTheme = true) { MagpieApp(model) } }
        } }
        compose.onNodeWithTag("following-list").performScrollToNode(hasContentDescription("Follow Morning news"))
        compose.onNodeWithContentDescription("Follow Morning news").assertIsDisplayed()
        capture("newsletter-senders-large-dark")
        compose.onNodeWithText("Settings").performClick()
        setting("Newsletters")
        compose.waitUntil(10_000) { model.newsletters.state.value.address != null }
        setting("Spell address"); compose.onNodeWithText("Spell address").assertIsDisplayed()
        capture("newsletter-address-large-dark")
        setting("Share address"); compose.onNodeWithText("Share address").assertIsDisplayed()
    }
}
