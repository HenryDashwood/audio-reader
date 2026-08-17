import Testing

@testable import Hearful

/// The suite must not make a sound.
///
/// Running the tests used to read a fixture article aloud and beep at the end
/// of it, out of the speakers of whatever Mac was running them — the voice and
/// the cues are real, and a simulator routes them straight out. These pin down
/// the defaults that keep it quiet, so a test written later cannot bring the
/// noise back by simply not thinking about it.
@MainActor
@Suite("The suite stays quiet")
struct SilenceUnderTestTests {
    @Test func aReaderBuiltWithoutASynthesizerSaysNothing() {
        #expect(SpeechSynthesizers.make() is SilentSynthesizer)
    }

    @Test func theSharedCuePlayerMakesNoSound() {
        #expect(Feedback.shared is SilentFeedback)
    }

    /// The check the two above rest on. If it ever stops recognising the test
    /// host, both quietly go back to the real thing.
    @Test func theTestEnvironmentIsRecognised() {
        #expect(TestEnvironment.isRunningTests)
    }
}
