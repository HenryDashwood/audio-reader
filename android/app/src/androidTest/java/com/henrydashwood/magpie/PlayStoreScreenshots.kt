package com.henrydashwood.magpie

import android.content.Intent
import android.graphics.Bitmap
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createEmptyComposeRule
import androidx.lifecycle.ViewModelProvider
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import androidx.test.platform.app.InstrumentationRegistry
import com.henrydashwood.magpie.data.*
import com.henrydashwood.magpie.playback.PlaybackService
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import org.junit.*
import java.io.File

/**
 * The Google Play phone screenshots, from the same fictional library as the App Store set
 * (`scripts/seed_app_store_screenshots.py`), so both stores show the same shows and issues.
 * Run with `make android-play-screenshots`; the ordinary suite skips it, because it switches
 * the emulator's status bar to demo mode and its screen to Play's 9:16 while it runs.
 */
class PlayStoreScreenshots {
    @get:Rule val compose = createEmptyComposeRule()
    private val app get() = ApplicationProvider.getApplicationContext<MagpieTestApplication>()
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private var scenario: ActivityScenario<MainActivity>? = null
    private lateinit var model: MagpieModel

    private fun shell(command: String) { instrumentation.uiAutomation.executeShellCommand(command).close() }
    private fun shellOutput(command: String) = android.os.ParcelFileDescriptor.AutoCloseInputStream(
        instrumentation.uiAutomation.executeShellCommand(command)).bufferedReader().use { it.readText() }

    @Before fun prepare() {
        Assume.assumeTrue("Run with make android-play-screenshots",
            InstrumentationRegistry.getArguments().getString("playScreenshots") == "true")
        app.stopService(Intent(app, PlaybackService::class.java))
        PreviewStore(app).lastItem = null
        val library = AccountLibrary(Fixture, "https://fixture.invalid")
        runBlocking(Dispatchers.Main) { library.changeSession("screenshots") }
        app.libraryOverride = library
        // Play Console accepts phone screenshots only at 16:9 or 9:16.
        shell("wm size 1080x1920")
        // British dates, as in the en-GB listing; a per-app language, reset afterwards.
        shell("cmd locale set-app-locales ${app.packageName} --locales en-GB")
        shell("settings put global sysui_demo_allowed 1")
        for (extras in listOf("-e command enter", "-e command clock -e hhmm 0941", "-e command battery -e level 100 -e plugged false",
            "-e command network -e wifi show -e level 4 -e mobile show -e level 4 -e datatype none", "-e command notifications -e visible false"))
            shell("am broadcast -a com.android.systemui.demo $extras")
        Thread.sleep(1_000)
        scenario = ActivityScenario.launch(MainActivity::class.java)
        scenario!!.onActivity { model = ViewModelProvider(it)[MagpieModel::class.java] }
        compose.waitUntil(15_000) { model.libraryState.value.let { it.live && it.items.isNotEmpty() } }
    }

    @After fun restore() {
        scenario?.close()
        app.libraryOverride = null
        app.stopService(Intent(app, PlaybackService::class.java))
        shell("am broadcast -a com.android.systemui.demo -e command exit")
        shell("wm size reset")
        shell("cmd locale set-app-locales ${app.packageName} --locales \"\"")
    }

    private fun capture(name: String) {
        // Injected input can leave touch mode, which draws focus rings on buttons.
        instrumentation.setInTouchMode(true)
        compose.waitForIdle()
        Thread.sleep(2_500) // artwork, the article WebView, and any list animation
        compose.waitForIdle()
        // A hung system app (often the launcher, after a display-size change) leaves a dialog over the shot.
        check("Application Not Responding" !in shellOutput("dumpsys window")) {
            "A system \"isn't responding\" dialog is on screen; restart the emulator and capture again."
        }
        val bitmap = checkNotNull(instrumentation.uiAutomation.takeScreenshot())
        val output = InstrumentationRegistry.getArguments().getString("additionalTestOutputDir")?.let(::File)
            ?: File(app.filesDir, "screenshots")
        output.mkdirs()
        // JPEG has no alpha channel, which Play Console rejects in PNGs.
        File(output, "$name.jpg").outputStream().use { bitmap.compress(Bitmap.CompressFormat.JPEG, 95, it) }
    }

    // A tab's name is also its screen's heading; only the tab is clickable.
    private fun tab(name: String) = compose.onNode(hasText(name) and hasClickAction()).performClick()

    @Test fun capturePhoneScreenshots() {
        tab("Following")
        compose.waitUntil(10_000) { compose.onAllNodesWithText("Science, Clearly").fetchSemanticsNodes().isNotEmpty() }
        capture("01-following")

        tab("Latest")
        compose.waitUntil(10_000) { compose.onAllNodesWithText("The Morning Ledger").fetchSemanticsNodes().isNotEmpty() }
        capture("02-latest")

        tab("Following")
        compose.onNodeWithText("The Slow Letter").performClick()
        compose.waitUntil(10_000) { compose.onAllNodesWithText("What the beans knew").fetchSemanticsNodes().isNotEmpty() }
        capture("03-newsletter")

        compose.onNodeWithText("Listening for the rain").performClick()
        compose.waitUntil(10_000) { model.libraryState.value.items.any { it.episodeId == 7 && it.textLoaded } }
        capture("04-issue")
        compose.onNodeWithContentDescription("Back").performClick()
        compose.onNodeWithContentDescription("Back").performClick()

        tab("Settings")
        compose.waitUntil(10_000) { compose.onAllNodesWithText("Playback Speed").fetchSemanticsNodes().isNotEmpty() }
        capture("05-settings")

        tab("Saved")
        compose.waitUntil(10_000) { compose.onAllNodesWithText("The objects we keep").fetchSemanticsNodes().isNotEmpty() }
        capture("06-saved")
    }

    /** The App Store fixture library, served without a backend. */
    private object Fixture : LibraryApi, NewsletterApi, DiscoveryApi {
        private fun art(colour: String, text: String) = "https://placehold.co/512x512/$colour/FFFFFF.png?text=$text"
        private val history = LibraryFeed("1", "The History Hour", 2, false, description = "Stories from the past, told by the people who know them best.",
            imageUrl = art("315A78", "HISTORY%0AHOUR"))
        private val science = LibraryFeed("2", "Science, Clearly", 2, false, description = "Big scientific ideas explained without the jargon.",
            imageUrl = art("0A7D6C", "SCIENCE%0ACLEARLY"))
        private val essays = LibraryFeed("3", "The Sunday Essay", 2, true, description = "Long-form writing about culture, technology and everyday life.",
            imageUrl = art("8A4F7D", "SUNDAY%0AESSAY"))
        private val slowLetter = LibraryFeed("4", "The Slow Letter", 2, true, description = "iris@theslowletter.example", newsletter = true)

        private val attention = """
            Somewhere in the last decade, doing one thing at a time became a skill rather than a default. We speak of it now the way earlier generations spoke of handwriting: admirable, slightly old-fashioned, and a little suspicious in anyone under forty.

            Yet the people I know who seem happiest in their work all share it. They answer messages at set hours. They read whole chapters. When they cook, the phone is in another room. None of them describe this as discipline; they describe it as relief.

            This essay is about what attention feels like when we stop dividing it, and about why the feeling is so easy to forget between one attempt and the next.
        """.trimIndent()
        private val objects = """
            My grandmother's kitchen scales sit on a shelf I pass every morning. They have not weighed anything in twenty years. They are not beautiful, and they are not rare; the same model turns up in every second charity shop in the country. I would carry them out of a burning house.

            We keep objects for what they remember on our behalf. A scale that once measured flour for a cake I was too small to see over the counter for is not a scale at all, but a small brass witness.

            This week: the things we cannot throw away, and what they are really for.
        """.trimIndent()
        private val rain = """
            There is a particular kind of quiet that only arrives once the kettle has boiled and the house has settled into itself. This week I have been trying to notice it on purpose, which turns out to be harder than noticing it by accident.

            A friend who keeps bees told me that the hive sounds different in the hour before rain. She cannot describe the difference, only that she hears it, and that she has stopped checking the forecast. I have been thinking about what else we know that way, and how rarely we trust it.

            So this week's small suggestion: pick one ordinary sound in your day and listen to it as if it were new. The lift arriving. The radiator ticking. The gate. Then write to me about what you heard.
        """.trimIndent()
        private val beans = """
            The allotment was under water for most of March, and I had written the year off. Then the beans came up anyway, all at once, as if they had been waiting for me to stop looking.

            I want to write this week about the things that happen while we are not paying attention, and about the difference between neglect and patience, which from the outside can look exactly alike. A garden knows which one it is getting. So, I suspect, do most of the people in our lives.

            Next week I will be away, so the letter will be a short one. Thank you, as ever, for reading.
        """.trimIndent()
        private val bodies = mapOf(3 to attention, 6 to objects, 7 to rain, 8 to beans, 101 to attention, 102 to rain, 103 to objects)
        private fun words(text: String) = text.split(Regex("\\s+")).count { it.isNotBlank() }
        private fun html(text: String) = text.split("\n\n").joinToString("") { "<p>${it.trim()}</p>" }

        private fun podcast(id: Int, feed: LibraryFeed, title: String, summary: String, date: String, position: Double = 0.0) =
            RemoteEpisode(id, title, summary, feed.title, audioUrl = "https://fixture.invalid/audio/$id.mp3", link = "https://fixture.invalid/episodes/$id",
                durationSeconds = 2_700 + id * 240, positionSeconds = position, publishedAt = date, imageUrl = feed.imageUrl)
        private fun article(id: Int, feed: LibraryFeed, title: String, summary: String, date: String, author: String) =
            RemoteEpisode(id, title, summary, feed.title, link = "https://fixture.invalid/episodes/$id", wordCount = words(bodies.getValue(id)),
                contentId = id, publishedAt = date, imageUrl = feed.imageUrl, author = author)

        private val episodes = listOf(
            article(7, slowLetter, "Listening for the rain", "On the sounds we know without being able to say how.", "2026-09-29T07:00:00Z", "Iris Marlow"),
            podcast(1, history, "The map that changed how we see the world", "A forgotten atlas and the argument hidden inside it.", "2026-09-28T06:00:00Z"),
            podcast(2, science, "Why birds know when to leave", "The remarkable senses behind a journey across continents.", "2026-09-27T06:00:00Z"),
            article(3, essays, "In praise of doing one thing at a time", "What attention feels like when we stop dividing it.", "2026-09-26T08:00:00Z", "Mara Bell"),
            podcast(4, history, "A city beneath the fields", "Archaeologists piece together a place absent from every record.", "2026-09-24T06:00:00Z", position = 1_280.0),
            podcast(5, science, "The quiet life of a forest at night", "Listening to the signals that pass between roots and leaves.", "2026-09-22T06:00:00Z"),
            article(8, slowLetter, "What the beans knew", "Patience and neglect look alike from the outside.", "2026-09-22T07:00:00Z", "Iris Marlow"),
            article(6, essays, "The objects we keep", "Why ordinary possessions can carry extraordinary memories.", "2026-09-20T08:00:00Z", "Mara Bell"),
        )
        private val saved = listOf(
            Triple(103, "The objects we keep", "commonplace.example"),
            Triple(102, "Listening for the rain", "smallhours.example"),
            Triple(101, "In praise of doing one thing at a time", "fieldnotes.example"),
        ).map { (id, title, host) ->
            RemoteEpisode(id, title, source = host, link = "https://$host/${title.substringAfterLast(' ')}", wordCount = words(bodies.getValue(id)), contentId = id)
        }
        private val feeds = listOf(history, science, essays, slowLetter)

        override suspend fun userId(token: String) = token
        override suspend fun feeds(token: String) = feeds
        override suspend fun latest(token: String) = episodes
        override suspend fun saved(token: String) = saved
        override suspend fun episodes(token: String, feedId: String, query: String) =
            feeds.first { it.id == feedId }.let { feed -> episodes.filter { it.source == feed.title } }
        override suspend fun search(token: String, query: String) = episodes.filter { it.title.contains(query, ignoreCase = true) }
        override suspend fun text(token: String, episodeId: Int, contentId: Int?): RemoteText {
            val body = bodies.getValue(episodeId)
            return RemoteText(episodeId, episodeId, body, html(body), words(body))
        }
        override suspend fun save(token: String, episodeId: Int?, url: String?): RemoteEpisode = error("Not used")
        override suspend fun remove(token: String, episodeId: Int) {}
        override suspend fun played(token: String, episodeId: Int, played: Boolean) {}
        override suspend fun clearLatest(token: String) {}
        override suspend fun subscribe(token: String, url: String): LibraryFeed = error("Not used")
        override suspend fun position(token: String, episodeId: Int, seconds: Double, completed: Boolean) {}
        override suspend fun directory(token: String, query: String) = emptyList<SourceResult>()
        override suspend fun discover(token: String, url: String) = emptyList<SourceResult>()
        override suspend fun preview(token: String, url: String): RemotePreview = error("Not used")
        override suspend fun webSearch(token: String, query: String): SourceResult? = null
        override suspend fun aiConsent(token: String) = true
        override suspend fun setAIConsent(token: String, granted: Boolean) = granted

        override suspend fun newsletterAddress(token: String) = NewsletterAddress("amber-finch-meadow@magpieinbox.com")
        override suspend fun pendingNewsletters(token: String) = listOf(PendingNewsletter(9, "The Morning Ledger",
            "briefing@morningledger.example", 2, "Thursday: what the rate decision means for savers"))
        override suspend fun approveNewsletter(token: String, feedId: Int): LibraryFeed = error("Not used")
        override suspend fun blockNewsletter(token: String, feedId: Int) {}
        override suspend fun signUpForNewsletter(token: String, url: String): NewsletterSignup = error("Not used")
    }
}
