import Foundation
import Testing

@testable import Hearful

@Suite("Sleep timer phrases")
struct SleepCommandTests {
    @Test(arguments: [
        "set a sleep timer for twenty minutes",
        "stop in twenty minutes",
        "turn off in twenty minutes",
        "go to sleep in 20 minutes",
        "stop playing in 20 minutes",
    ])
    func twentyMinutesIsHeard(_ phrase: String) {
        #expect(SleepCommand.match(phrase) == .after(minutes: 20))
    }

    @Test func halfAnHour() {
        #expect(SleepCommand.match("stop in half an hour") == .after(minutes: 30))
    }

    @Test func anHour() {
        #expect(SleepCommand.match("sleep timer for an hour") == .after(minutes: 60))
    }

    @Test func anHourAndAHalf() {
        #expect(SleepCommand.match("stop in an hour and a half") == .after(minutes: 90))
    }

    @Test func compoundNumbers() {
        #expect(SleepCommand.match("stop in twenty five minutes") == .after(minutes: 25))
    }

    @Test func aBareSleepTimerGetsTheDefault() {
        #expect(SleepCommand.match("set a sleep timer") == .after(minutes: 30))
    }

    @Test(arguments: [
        "cancel the sleep timer",
        "turn off the sleep timer",
        "no sleep timer",
        "forget the sleep timer",
    ])
    func cancellingIsHeard(_ phrase: String) {
        #expect(SleepCommand.match(phrase) == .cancel)
    }

    @Test func aDurationBeatsTheCancelWords() {
        // "turn it off in twenty minutes" is setting a timer, not clearing one.
        #expect(SleepCommand.match("turn it off in twenty minutes") == .after(minutes: 20))
    }

    @Test(arguments: ["pause", "stop", "play", "skip", "go back"])
    func transportCommandsAreNotSleepCommands(_ phrase: String) {
        // A bare "stop" is a pause. Stealing it would mean the most-used
        // control in the app silently set a timer instead.
        #expect(SleepCommand.match(phrase) == nil)
    }

    @Test(arguments: [
        "play the one about sleep",
        "play the sleep episode",
        "subscribe to sleepy history",
        "play the latest episode",
        "play the twenty minute one about sleep",
        "find me something about going to bed",
        "read the article about sleep",
    ])
    func realRequestsAreLeftAlone(_ phrase: String) {
        // Sleep is also a subject people make podcasts about. Hijacking one of
        // these would leave her in silence, having asked to hear something,
        // with no clue why nothing started.
        #expect(SleepCommand.match(phrase) == nil)
    }

    @Test func absurdDurationsAreRejected() {
        // Far more likely a mishearing than a request.
        #expect(SleepCommand.match("stop in 5000 minutes") == nil)
    }
}

@Suite("Sleep timer")
@MainActor
struct SleepTimerTests {
    private func makeTimer(recorder: Recorder) -> (SleepTimer, PlaybackCoordinator) {
        let player = PlaybackCoordinator(audio: AudioPlayer(), article: ArticlePlayer(api: FakeAPI()))
        let timer = SleepTimer(player: player, feedback: FakeFeedback(recorder))
        return (timer, player)
    }

    @Test func startingSetsAnEndTime() {
        let (timer, _) = makeTimer(recorder: Recorder())
        timer.start(minutes: 20)

        #expect(timer.isRunning)
        let remaining = timer.remaining ?? 0
        #expect(remaining > 19 * 60 && remaining <= 20 * 60)
    }

    @Test func cancellingClearsIt() {
        let (timer, _) = makeTimer(recorder: Recorder())
        timer.start(minutes: 20)
        timer.cancel()

        #expect(!timer.isRunning)
        #expect(timer.remaining == nil)
    }

    @Test func startingAgainReplacesTheFirst() {
        let (timer, _) = makeTimer(recorder: Recorder())
        timer.start(minutes: 60)
        timer.start(minutes: 5)

        #expect((timer.remaining ?? 0) <= 5 * 60)
    }

    @Test func firingClearsTheTimer() {
        let (timer, _) = makeTimer(recorder: Recorder())
        timer.start(minutes: 20)
        timer.fire()

        #expect(!timer.isRunning)
    }

    @Test func firingWhileAlreadyPausedMakesNoSound() {
        // She stopped it herself before the timer came round; a chime out of
        // nowhere would be worse than nothing.
        let recorder = Recorder()
        let (timer, _) = makeTimer(recorder: recorder)
        timer.start(minutes: 20)
        timer.fire()

        #expect(!recorder.events.contains(.cue(.finished)))
    }

    @Test func durationsAreSpokenAsWords() {
        #expect(SleepTimer.spokenDuration(minutes: 30) == "half an hour")
        #expect(SleepTimer.spokenDuration(minutes: 60) == "an hour")
        #expect(SleepTimer.spokenDuration(minutes: 20) == "20 minutes")
    }
}
