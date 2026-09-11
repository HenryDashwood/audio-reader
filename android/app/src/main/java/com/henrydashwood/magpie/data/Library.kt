package com.henrydashwood.magpie.data

enum class ContentKind { Podcast, Article }

data class LibraryItem(
    val id: String,
    val source: String,
    val title: String,
    val description: String,
    val kind: ContentKind,
    val durationLabel: String,
    val text: String,
    val contentVersion: String = "sample-v1",
    val originalUrl: String? = null,
    // Display HTML (including backend-rendered MathML) is separate from immutable speech text.
    val html: String? = null,
    val episodeId: Int? = null,
    val contentId: Int? = null,
    val sourceId: String = source,
    val audioUrl: String? = null,
    val wordCount: Int? = null,
    val textLoaded: Boolean = true,
    val remotePositionMs: Long = 0,
    val completed: Boolean = false,
    val dismissed: Boolean = false,
    val captureError: String? = null,
)

interface LibraryRepository {
    val items: List<LibraryItem>
}

/** Original sample content; never mixed with a signed-in account or a server library. */
class SampleLibrary : LibraryRepository {
    override val items = listOf(
        LibraryItem(
            "welcome", "Magpie journal", "A little more room to listen",
            "A short introduction to a quieter way of keeping up.",
            ContentKind.Podcast, "1 min", welcomeTranscript,
        ),
        LibraryItem(
            "walking", "Field notes", "The pleasure of taking the long way home",
            "What we notice when we give a familiar journey a little more time.",
            ContentKind.Article, "2 min read",
            """There is a turning near home that I usually walk past. It leads away from the main road, alongside a row of gardens, and eventually comes back to the same place. It adds ten minutes to the journey. For a long time, that was reason enough not to take it.

                |One evening I turned down it anyway. Someone had left a bowl of water beside their gate. A blackbird was making a remarkable amount of noise for such a small creature. Further along, the pavement widened beneath an old tree, and I stopped for no particular reason.

                |Nothing important happened. That was part of the pleasure. The walk did not need to become an achievement, a photograph, or a story worth telling. It was simply a little unclaimed time.

                |Since then, I have been thinking about the small choices that make a day feel less hurried. Reading a few pages before opening the news. Listening to one thing all the way through. Leaving enough room between appointments to arrive without running.

                |Taking the long way home is not always possible. But sometimes the extra ten minutes are not time lost. They are the part of the day we remember.""".trimMargin(),
        ),
        LibraryItem(
            "listening", "Magpie journal", "Make yourself at home",
            "A few things to try in this early Android preview.",
            ContentKind.Article, "1 min read",
            """Welcome to Magpie. This preview gives you a small sample library to explore before connecting an account.

                |Following brings together the sources in your library. Latest collects their episodes and articles. Saved keeps the things you would like to come back to.

                |Open an article to read it, or choose Listen to have an installed offline voice read it aloud. Playback controls remain available as you move around the app. You can pause, go back, or change the listening speed.

                |These are sample stories. Your real subscriptions and saved articles are not connected yet. Nothing you do here changes your library on another device.""".trimMargin(),
        ),
        LibraryItem(
            "morning", "Field notes", "Before the rest of the day begins",
            "Finding a small pocket of attention in an ordinary morning.",
            ContentKind.Article, "1 min read",
            """A morning does not have to be perfectly quiet to offer a moment of calm. There might be traffic outside, a kettle beginning to boil, or someone looking for their keys.

                |Even so, it is possible to choose one thing to pay attention to. The first paragraph of an article. A voice telling a story. The light moving across a wall.

                |The point is not to shut everything else out. It is to begin with something chosen, before the day fills itself with everything that asks for our attention.""".trimMargin(),
        ),
        RichArticleSample.item,
    )

    companion object {
        val welcomeTranscript = """Welcome to Magpie. This is a short sample recording for trying the Android player.

            |Magpie brings podcasts and written articles into one place, so you can choose something interesting and keep listening as you go about your day.

            |Try pausing this recording, moving back a few seconds, or changing the playback speed. You can also leave this screen and use the small player above the navigation bar.

            |When you are ready, open Field notes and listen to an article. The words will be prepared on your device using an installed offline voice.

            |This is an early preview with a sample library. Thank you for taking it for a spin.""".trimMargin()
    }
}
