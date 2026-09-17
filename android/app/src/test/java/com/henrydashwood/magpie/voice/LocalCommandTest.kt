package com.henrydashwood.magpie.voice

import org.junit.Assert.*
import org.junit.Test

class LocalCommandTest {
    @Test fun directTransportCommandsHandlePolitenessAndPunctuation() {
        listOf("pause", "Can you pause, please?", "STOP!", "be quiet", "shush", "hold on").forEach {
            assertEquals(it, LocalCommand.Pause, LocalCommand.match(it))
        }
        listOf("resume", "carry on", "keep going", "play", "unpause").forEach {
            assertEquals(it, LocalCommand.Resume, LocalCommand.match(it))
        }
        assertEquals(LocalCommand.Seek(30.0), LocalCommand.match("skip ahead"))
        assertEquals(LocalCommand.Seek(-15.0), LocalCommand.match("go back a bit"))
        assertEquals(LocalCommand.Seek(-15.0), LocalCommand.match("what was that"))
    }
    @Test fun contentRequestsAreNeverMistakenForPlaybackOrSleepControls() {
        listOf("play the one about Rome", "go back to the Rome episode", "find something about sleep",
            "read the sleep timer article", "play the one about sleep", "explain the sleep timer", "what is a sleep timer",
            "that's all about history", "resume the history show", "speed up the search", "pause after this episode").forEach {
            assertNull(it, LocalCommand.match(it))
        }
    }
    @Test fun relativeAndAbsoluteSpeedCommandsMatchIosRanges() {
        assertEquals(LocalCommand.AdjustSpeed(.25f), LocalCommand.match("speed it up"))
        assertEquals(LocalCommand.AdjustSpeed(-.25f), LocalCommand.match("not so fast"))
        assertEquals(LocalCommand.Speed(1f), LocalCommand.match("usual speed"))
        mapOf("play at 1.25x" to 1.25f, "set speed to one point five" to 1.5f,
            "playback speed half" to .5f, "speed 3" to 3f, "play at two and a half times speed" to 2.5f).forEach { (words, rate) ->
            assertEquals(words, LocalCommand.Speed(rate), LocalCommand.match(words))
        }
        listOf("speed 0", "speed 4", "speed NaN", "play at -1", "play at (-1)", "play at Infinity").forEach { assertNull(it, LocalCommand.match(it)) }
    }
    @Test fun parameterizedSeekIsNotASpeedChange() {
        mapOf("fast forward three minutes" to 180.0, "go back by thirty seconds" to -30.0,
            "skip back one hour" to -3600.0, "jump forward 0.5 minutes" to 30.0,
            "rewind two hours" to -7200.0).forEach { (words, seconds) ->
            assertEquals(words, LocalCommand.Seek(seconds), LocalCommand.match(words))
        }
        listOf("rewind three hours", "skip forward -30 seconds", "rewind zero seconds").forEach { assertNull(it, LocalCommand.match(it)) }
    }
    @Test fun sleepCommandsTakePrecedenceOverPauseAndHaveExplicitLimits() {
        mapOf("stop in twenty minutes" to 20, "stop playing in twenty five minutes" to 25,
            "turn it off in half an hour" to 30, "sleep timer an hour and a half" to 90,
            "set a sleep timer" to 30, "sleep timer 720 minutes" to 720).forEach { (words, minutes) ->
            assertEquals(words, LocalCommand.Sleep(minutes), LocalCommand.match(words))
        }
        listOf("cancel the sleep timer", "sleep timer off", "stop the timer").forEach { assertEquals(LocalCommand.CancelSleep, LocalCommand.match(it)) }
        listOf("sleep", "bed", "sleep timer 999 hours", "sleep timer 0 minutes", "sleep timer -5 minutes",
            "sleep timer 1.5 hours", "sleep timer ten seconds", "sleep timer one hour thirty minutes", "sleep timer two hours and a half", "sleep timer 999999999999999999999 minutes").forEach { assertNull(it, LocalCommand.match(it)) }
    }
    @Test fun conversationEndAndUndoRequireUnambiguousPhrases() {
        listOf("That's all.", "That’s all, thanks!", "goodbye Magpie", "end the conversation").forEach {
            assertEquals(it, LocalCommand.EndConversation, LocalCommand.match(it))
        }
        assertEquals(LocalCommand.Undo, LocalCommand.match("undo that"))
        assertNull(LocalCommand.match("undo that subscription to the wrong show"))
    }
}
