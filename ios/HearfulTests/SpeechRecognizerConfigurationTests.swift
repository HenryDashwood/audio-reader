import Testing

@testable import Hearful

@Suite("Speech recognizer configuration")
@MainActor
struct SpeechRecognizerConfigurationTests {
    @Test func retainsLiveGuessesWithoutTradingAwayAccuracy() {
        let preset = AnalyzerSpeechRecognizer.accuracyBiasedPreset

        #expect(preset.reportingOptions.contains(.volatileResults))
        #expect(!preset.reportingOptions.contains(.frequentFinalization))
        #expect(preset.contentHints.contains(.shortForm))
        #expect(preset.contentHints.contains(.farField))
    }
}
