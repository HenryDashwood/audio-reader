package com.henrydashwood.magpie.voice

import org.junit.Assert.*
import org.junit.Test

class DownloadPhrasesTest {
    @Test fun downloadingWhatIsPlaying() {
        listOf("download this", "Download this episode.", "can you download this please", "download it",
            "save this for offline", "Download this one for offline").forEach {
            assertEquals(it, LocalCommand.Download, LocalCommand.match(it))
        }
        listOf("remove this download", "delete the download", "remove this from my downloads").forEach {
            assertEquals(it, LocalCommand.RemoveDownload, LocalCommand.match(it))
        }
    }

    @Test fun anythingNamingOtherEpisodesIsLeftForTheModel() {
        listOf("download the new episode of In Our Time", "download the next three episodes", "play this", "downloads").forEach {
            assertNotEquals(it, LocalCommand.Download, LocalCommand.match(it))
        }
    }

    @Test fun answers() {
        assertEquals(DownloadPhrases.Reply.Yes, DownloadPhrases.reply("Yes please"))
        assertEquals(DownloadPhrases.Reply.Yes, DownloadPhrases.reply("download it anyway"))
        assertEquals(DownloadPhrases.Reply.WaitForWifi, DownloadPhrases.reply("wait for Wi-Fi"))
        assertEquals(DownloadPhrases.Reply.No, DownloadPhrases.reply("No thank you."))
        assertNull(DownloadPhrases.reply("play the news"))
    }
}
