import Foundation
import Testing

@testable import Hearful

@Suite("Listening timeouts")
struct ListeningTimeoutTests {
    @Test func waitsMuchLongerBeforeSheHasSaidAnything() {
        // The gap between tapping and starting to speak is not silence at the
        // end of a sentence, and must not be treated as one.
        let timeouts = ListeningTimeouts()
        #expect(
            timeouts.interval(hasHeardSpeech: false, isSettled: true)
                > timeouts.interval(hasHeardSpeech: true, isSettled: true))
    }

    @Test func opensWithEnoughTimeToGatherAThought() {
        #expect(ListeningTimeouts().interval(hasHeardSpeech: false, isSettled: true) >= 6)
    }

    @Test func endsSoonAfterSheHasStoppedAndTheWordsHaveSettled() {
        // Dead air before the episode starts, so it should not drag — but it
        // used to be a single second, which cut her off mid-thought.
        let settled = ListeningTimeouts().interval(hasHeardSpeech: true, isSettled: true)
        #expect(settled >= 1.75)
        #expect(settled <= 2.5)
    }

    @Test func keepsListeningWhileTheRecogniserIsStillRevising() {
        // The failure this exists for: acting on an unfinalised transcript
        // sent "play the in our stand" — a show named, no episode, so the
        // newest episode of that show played instead of the one she asked
        // for. Waiting costs a moment; guessing costs the wrong programme,
        // with no screen to notice it on.
        let timeouts = ListeningTimeouts()
        #expect(
            timeouts.interval(hasHeardSpeech: true, isSettled: false)
                > timeouts.interval(hasHeardSpeech: true, isSettled: true))
    }

    @Test func stillGivesUpEventuallyOnATranscriptThatNeverSettles() {
        // The long wait is a backstop, not a hang: she must always get an
        // answer, even if the recogniser never commits.
        #expect(ListeningTimeouts().interval(hasHeardSpeech: true, isSettled: false) <= 5)
    }

    @Test func waitingToBeginStillOutlastsWaitingForWordsToSettle() {
        // VoiceOver announces the screen before she can start, and that wait
        // has to outlast every other.
        let timeouts = ListeningTimeouts()
        #expect(
            timeouts.interval(hasHeardSpeech: false, isSettled: false)
                > timeouts.interval(hasHeardSpeech: true, isSettled: false))
    }
}

@Suite("Microphone route")
struct MicrophoneRouteTests {
    @Test func acceptsAWorkingRoute() {
        #expect(AudioSession.isUsableInputFormat(sampleRate: 48000, channelCount: 1))
    }

    @Test func rejectsARouteWithNoSampleRate() {
        // What the input node reports after the audio session has been to
        // playback and back. Handing it to installTap raises an Objective-C
        // exception that Swift cannot catch, so the app dies with SIGABRT
        // rather than falling back or saying anything. Observed four times in
        // one evening, always on the second attempt after a failed one.
        #expect(!AudioSession.isUsableInputFormat(sampleRate: 0, channelCount: 1))
    }

    @Test func rejectsARouteWithNoChannels() {
        #expect(!AudioSession.isUsableInputFormat(sampleRate: 48000, channelCount: 0))
    }
}
