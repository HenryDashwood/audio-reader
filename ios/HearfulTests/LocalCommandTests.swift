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

    @Test(arguments: ["skip", "skip forward", "skip ahead", "jump forward", "forward"])
    func recognisesSkipForward(_ transcript: String) {
        #expect(TransportCommand.match(transcript) == .skipForward)
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
        "play at one and a half speed",
        "double speed",
        "",
        "   ",
    ])
    func leavesRealRequestsToTheBackend(_ transcript: String) {
        #expect(TransportCommand.match(transcript) == nil)
    }
}
