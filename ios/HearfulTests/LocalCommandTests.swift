import Testing

@testable import Hearful

@Suite("Local transport commands")
struct LocalCommandTests {
    @Test(arguments: [
        "pause", "Pause.", "pause please", "stop", "stop please", "be quiet",
        "shush", "quiet", "can you pause", "hold on",
    ])
    func recognisesPause(_ transcript: String) {
        #expect(TransportCommand.match(transcript) == .pause)
    }

    @Test(arguments: [
        "resume", "continue", "carry on", "keep going", "go on", "unpause",
        "play", "carry on please", "start again",
    ])
    func recognisesResume(_ transcript: String) {
        #expect(TransportCommand.match(transcript) == .resume)
    }

    @Test(arguments: ["skip", "skip forward", "skip ahead", "jump forward", "forward", "fast forward"])
    func recognisesSkipForward(_ transcript: String) {
        #expect(TransportCommand.match(transcript) == .skipForward)
    }

    @Test(arguments: [
        "fast forward three minutes", "fast forward 3 minutes",
        "Can you fast-forward three minutes, please?", "fast forward by three minutes",
    ])
    func fastForwardWithMinutesSeeksInsteadOfChangingSpeed(_ transcript: String) {
        #expect(TransportCommand.match(transcript) == .seek(180))
    }

    @Test func fastForwardRespectsDurationUnits() {
        #expect(TransportCommand.match("fast forward thirty seconds") == .seek(30))
        #expect(TransportCommand.match("fast forward one hour") == .seek(3600))
    }

    @Test(arguments: ["play at three times speed", "set speed to 3x", "playback speed three"])
    func explicitSpeedRequestsStillChangeSpeed(_ transcript: String) {
        #expect(TransportCommand.match(transcript) == .speed(3))
    }

    @Test(arguments: [
        "go back", "back", "rewind", "say that again", "repeat that", "what was that",
    ])
    func recognisesSkipBack(_ transcript: String) {
        #expect(TransportCommand.match(transcript) == .skipBack)
    }

    @Test(arguments: [
        "faster", "speed up", "speed it up", "quicker", "go faster", "too slow",
        "can you go faster please",
    ])
    func recognisesFaster(_ transcript: String) {
        #expect(TransportCommand.match(transcript) == .faster)
    }

    @Test(arguments: ["slower", "slow down", "slow it down", "not so fast", "too fast"])
    func recognisesSlower(_ transcript: String) {
        #expect(TransportCommand.match(transcript) == .slower)
    }

    @Test(arguments: ["normal speed", "regular speed", "usual speed"])
    func recognisesNormalSpeed(_ transcript: String) {
        #expect(TransportCommand.match(transcript) == .normalSpeed)
    }

    // The dangerous direction: a false match here would break the whole app,
    // turning a real request into a silent transport nudge.
    @Test(arguments: [
        "play the one about the aliens lady",
        "play the latest joe rogan",
        "play the seashells episode",
        "subscribe to the rest is history",
        "what's new",
        "stop playing joe rogan and put on in our time",
        "go back to the episode about Rome",
        "skip to the one with Annie Jacobsen",
        "double speed",
        "fast forward three",
        "fast forward three times speed",
        "fast forward three hours",
        "fast forward to the episode about three minutes",
        "fast forward three minutes and play another episode",
        "",
        "   ",
    ])
    func leavesRealRequestsToTheBackend(_ transcript: String) {
        #expect(TransportCommand.match(transcript) == nil)
    }
}
