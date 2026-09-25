package com.henrydashwood.magpie.data

import org.junit.Assert.*
import org.junit.Test
import java.time.ZoneId
import java.util.Locale

class ListeningPresentationTest {
    private val podcast = LibraryItem("one", "Show", "Episode", "", ContentKind.Podcast, "10 min", "",
        remotePositionMs = 125_000, durationSeconds = 600)
    @Test fun podcastProgressUsesTheSuppliedLiveClockAndActualCompletion() {
        assertEquals("8 min left", listeningPresentation(podcast).label)
        val live = listeningPresentation(podcast, positionMs = 240_000, durationMs = 420_000)
        assertEquals("3 min left", live.label); assertTrue(live.started)
        assertEquals(240f / 420f, live.fraction!!, .001f)
        assertEquals("1 min left", listeningPresentation(podcast, positionMs = 599_000).label) // as iOS: never "0 min"
        assertEquals("Played", listeningPresentation(podcast, completed = true).label)
        assertFalse(listeningPresentation(podcast, completed = true).started)
    }
    @Test fun shortFalseStartsUnknownDurationAndDismissalAreDistinct() {
        assertNull(listeningPresentation(podcast, positionMs = 60_000).label)
        assertFalse(listeningPresentation(podcast, positionMs = -1).started)
        val unknown = listeningPresentation(podcast.copy(durationSeconds = null))
        assertNull(unknown.label); assertTrue(unknown.started); assertNull(unknown.fraction)
        assertFalse(listeningPresentation(podcast.copy(dismissed = true)).started)
    }
    @Test fun articlesUseMatchingUtf16CoordinatesRatherThanRenderedSeconds() {
        val article = podcast.copy(kind = ContentKind.Article, text = "Café 🌱 and a bird.", contentVersion = "a".repeat(64),
            remotePositionMs = 0, articleBookmark = RemoteArticleBookmark("a".repeat(64), 8))
        val progress = listeningPresentation(article)
        assertTrue(progress.started); assertNull(progress.label)
        assertEquals(8f / article.text.length, progress.fraction!!, .001f)
        assertFalse(listeningPresentation(article.copy(contentVersion = "replacement")).started)
        assertEquals("Played", listeningPresentation(article, completed = true).label)
        assertTrue(listeningPresentation(article.copy(textLoaded = false)).started)
    }
    @Test fun publicationDatesRespectTheReadersZoneAndOldUtcSnapshots() {
        assertEquals("16 Sept 2026", publicationDate("2026-09-17T00:30:00Z", ZoneId.of("America/Los_Angeles"), Locale.UK))
        assertEquals("17 Sept 2026", publicationDate("2026-09-17T00:30:00", ZoneId.of("UTC"), Locale.UK))
        assertNull(publicationDate(null)); assertNull(publicationDate("not a date"))
        assertEquals("16 Sep", shortPublicationDate("2026-09-17T00:30:00Z", ZoneId.of("America/Los_Angeles"), Locale.UK))
        assertEquals("Sep 17", shortPublicationDate("2026-09-17T00:30:00Z", ZoneId.of("UTC"), Locale.US))
    }
    @Test fun artworkOnlyAcceptsPublisherHttpsUrlsWithoutEmbeddedCredentials() {
        assertEquals("https://example.com/cover.png", publisherArtwork("https://example.com/cover.png"))
        for (invalid in listOf(null, "http://example.com/image", "file:///private/image", "content://image", "https://user:password@example.com/cover", "not a URL"))
            assertNull(publisherArtwork(invalid))
    }
}
