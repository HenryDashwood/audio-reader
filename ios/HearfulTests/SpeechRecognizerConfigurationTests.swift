import Testing

@testable import Hearful

@Suite("Speech recognizer configuration")
@MainActor
struct SpeechRecognizerConfigurationTests {
    @Test func retainsLiveGuessesWithoutTradingAwayAccuracy() {
        let options = AnalyzerSpeechRecognizer.accuracyBiasedPreset.reportingOptions

        #expect(options.contains(.volatileResults))
        #expect(!options.contains(.fastResults))
    }
}
